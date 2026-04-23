{
  lz4.pas - Free Pascal port of the LZ4 block compression algorithm.

  Ported from the reference C implementation (lz4.c / lz4.h v1.10.0) by Yann Collet.
  Original C code: Copyright (C) 2011-2023, Yann Collet, BSD 2-Clause License.
  See https://github.com/lz4/lz4 for the reference implementation.

  This unit implements the LZ4 block format:
    - TLZ4.CompressBound   : worst-case output size
    - TLZ4.Compress        : single-shot block compression (acceleration = 1)
    - TLZ4.CompressFast    : single-shot block compression with custom acceleration
    - TLZ4.Decompress      : safe block decompression

  Convenience wrappers are provided for TBytes and TStream. The stream helpers
  prefix the compressed payload with a 4-byte little-endian uncompressed size,
  so round-tripping is self-contained. This is *not* the LZ4 frame format used
  by the lz4 command-line tool - it is a minimal container for the block format.

  The implementation is portable Pascal; it assumes a little-endian target
  (x86, x86_64, ARM little-endian, etc.). FPC on Windows/Linux x86_64 is fine.

  Limitations vs the reference C code:
    - No streaming compression, no dictionaries.
    - Single-threaded, single-pass.
    - No partial decoding.
  The emitted blocks are standard LZ4 blocks, decodable by any compliant
  LZ4 decoder, including the reference liblz4 and lz4 CLI (block mode).
}
unit lz4;

{$mode objfpc}{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, Classes;

const
  LZ4_VERSION_MAJOR    = 1;
  LZ4_VERSION_MINOR    = 10;
  LZ4_VERSION_RELEASE  = 0;
  LZ4_VERSION_NUMBER   = LZ4_VERSION_MAJOR * 10000 + LZ4_VERSION_MINOR * 100 + LZ4_VERSION_RELEASE;
  LZ4_VERSION_STRING   = '1.10.0';

  LZ4_MAX_INPUT_SIZE        = $7E000000;   // ~2.11 GB
  LZ4_DISTANCE_MAX          = 65535;
  LZ4_ACCELERATION_DEFAULT  = 1;
  LZ4_ACCELERATION_MAX      = 65537;

type
  ELZ4Error = class(Exception);

  { Low-level buffer API + convenience wrappers grouped under a namespace. }
  TLZ4 = class
  public
    { Maximum possible compressed size for InputSize uncompressed bytes.
      Returns 0 if InputSize is out of range. }
    class function CompressBound(InputSize: Integer): Integer; static;

    { Compress SrcSize bytes from Src into Dst (capacity DstCapacity).
      Returns number of bytes written, or 0 if Dst is too small or on error.
      This is the raw block format; caller must remember SrcSize to decompress. }
    class function Compress(Src, Dst: Pointer; SrcSize, DstCapacity: Integer): Integer; static;

    { As Compress, but allows selecting an acceleration factor >= 1.
      Higher = faster but worse compression. Values outside [1..LZ4_ACCELERATION_MAX]
      are clamped. }
    class function CompressFast(Src, Dst: Pointer; SrcSize, DstCapacity, Acceleration: Integer): Integer; static;

    { Decompress a block. CompressedSize must be the exact size of the block.
      DstCapacity must be >= the original uncompressed size.
      Returns the number of decompressed bytes (>= 0) on success,
      or a negative value on corrupted/invalid input. }
    class function Decompress(Src, Dst: Pointer; CompressedSize, DstCapacity: Integer): Integer; static;

    { Decompress a block that may reference back into a prefix of PrefixSize
      bytes immediately preceding Dst (used for the "linked blocks" mode of
      the LZ4 frame format, i.e. LZ4_decompress_safe_withPrefix64k).
      PrefixSize must be <= 65536. }
    class function DecompressWithPrefix(Src, Dst: Pointer;
      CompressedSize, DstCapacity, PrefixSize: Integer): Integer; static;

    { TBytes-based wrappers }
    class function CompressBytes(const Source: TBytes; Acceleration: Integer = LZ4_ACCELERATION_DEFAULT): TBytes; static;
    class function DecompressBytes(const Source: TBytes; OriginalSize: Integer): TBytes; static;

    { Stream wrappers. The output format is:
        [4 bytes LE: original uncompressed size]
        [compressed LZ4 block payload]
      CompressStream reads the remainder of InStream from its current position;
      DecompressStream is the exact inverse. Both return the number of bytes
      written to OutStream. }
    class function CompressStream(InStream, OutStream: TStream;
      Acceleration: Integer = LZ4_ACCELERATION_DEFAULT): Int64; static;
    class function DecompressStream(InStream, OutStream: TStream): Int64; static;
  end;

{ Free-standing aliases, for callers who prefer plain procedures. }
function LZ4CompressBound(InputSize: Integer): Integer; inline;
function LZ4Compress(Src, Dst: Pointer; SrcSize, DstCapacity: Integer): Integer; inline;
function LZ4CompressFast(Src, Dst: Pointer; SrcSize, DstCapacity, Acceleration: Integer): Integer; inline;
function LZ4Decompress(Src, Dst: Pointer; CompressedSize, DstCapacity: Integer): Integer; inline;

implementation

{ -------------------------------------------------------------------------
  Block-format constants (see doc/lz4_Block_format.md in the reference repo)
  ------------------------------------------------------------------------- }
const
  MINMATCH        = 4;
  WILDCOPYLENGTH  = 8;
  LASTLITERALS    = 5;
  MFLIMIT         = 12;
  LZ4_minLength   = MFLIMIT + 1;

  ML_BITS   = 4;
  ML_MASK   = (1 shl ML_BITS) - 1;               // 15
  RUN_BITS  = 8 - ML_BITS;                       // 4
  RUN_MASK  = (1 shl RUN_BITS) - 1;              // 15

  LZ4_MEMORY_USAGE   = 14;
  LZ4_HASHLOG        = LZ4_MEMORY_USAGE - 2;     // 12
  LZ4_HASH_SIZE_U32  = 1 shl LZ4_HASHLOG;        // 4096
  LZ4_64Klimit       = (64 * 1024) + (MFLIMIT - 1);
  LZ4_skipTrigger    = 6;

type
  TLZ4HashTable = array[0..LZ4_HASH_SIZE_U32 - 1] of UInt32;
  PLZ4HashTable = ^TLZ4HashTable;

{ -------------------------------------------------------------------------
  Low-level unaligned memory helpers.
  Pascal's typed-pointer deref already supports unaligned access on x86/x64
  via @ and dereference. We use Move() for variable-length copies to let
  the RTL pick the best implementation.
  ------------------------------------------------------------------------- }

function LZ4ReadU32(P: PByte): UInt32; inline;
begin
  Result := PUInt32(P)^;
end;

function LZ4ReadU16(P: PByte): UInt16; inline;
begin
  Result := PUInt16(P)^;
end;

procedure LZ4WriteU16LE(P: PByte; Value: UInt16); inline;
begin
  // All common FPC targets are little-endian; if we ever need big-endian
  // support, branch on NtoLE(Value) here.
  PUInt16(P)^ := Value;
end;

function LZ4ReadU16LE(P: PByte): UInt16; inline;
begin
  Result := PUInt16(P)^;
end;

{ LZ4's hash for 4-byte sequences. Maps a 32-bit word to a HASHLOG-bit index.
  CRITICAL: the multiplication must wrap at 32 bits. We cast to UInt32 after
  each operation and AND with the table-size mask at the end, so an accidental
  64-bit promotion by the compiler cannot produce an out-of-range index. }
function LZ4Hash4(Sequence: UInt32): UInt32; inline;
var
  Product: UInt32;
begin
  Product := UInt32(Sequence * UInt32(2654435761));
  Result := (Product shr ((MINMATCH * 8) - LZ4_HASHLOG)) and (LZ4_HASH_SIZE_U32 - 1);
end;

function LZ4HashPosition(P: PByte): UInt32; inline;
begin
  Result := LZ4Hash4(LZ4ReadU32(P));
end;

{ Count matching bytes between two pointers, bounded by PInLimit.
  Uses 64-bit XOR + trailing-zero-count for bulk matching, byte-wise for tail. }
function LZ4NbCommonBytes64(Val: UInt64): UInt32; inline;
begin
  // Count trailing zero bytes (little-endian). BsfQWord returns bit index 0..63.
  // Val is guaranteed non-zero by caller.
  Result := BsfQWord(Val) shr 3;
end;

function LZ4NbCommonBytes32(Val: UInt32): UInt32; inline;
begin
  Result := BsfDWord(Val) shr 3;
end;

function LZ4Count(PIn, PMatch, PInLimit: PByte): UInt32;
var
  PStart: PByte;
  Diff64: UInt64;
  Diff32: UInt32;
begin
  PStart := PIn;

{$IFDEF CPU64}
  // 64-bit fast path: compare 8 bytes at a time.
  if PIn < (PInLimit - 7) then
  begin
    Diff64 := PUInt64(PMatch)^ xor PUInt64(PIn)^;
    if Diff64 = 0 then
    begin
      Inc(PIn, 8);
      Inc(PMatch, 8);
    end
    else
    begin
      Result := LZ4NbCommonBytes64(Diff64);
      Exit;
    end;
  end;

  while PIn < (PInLimit - 7) do
  begin
    Diff64 := PUInt64(PMatch)^ xor PUInt64(PIn)^;
    if Diff64 = 0 then
    begin
      Inc(PIn, 8);
      Inc(PMatch, 8);
      Continue;
    end;
    Inc(PIn, LZ4NbCommonBytes64(Diff64));
    Result := UInt32(PIn - PStart);
    Exit;
  end;

  if (PIn < (PInLimit - 3)) and (PUInt32(PMatch)^ = PUInt32(PIn)^) then
  begin
    Inc(PIn, 4);
    Inc(PMatch, 4);
  end;
{$ELSE}
  // 32-bit fast path: compare 4 bytes at a time.
  while PIn < (PInLimit - 3) do
  begin
    Diff32 := PUInt32(PMatch)^ xor PUInt32(PIn)^;
    if Diff32 = 0 then
    begin
      Inc(PIn, 4);
      Inc(PMatch, 4);
      Continue;
    end;
    Inc(PIn, LZ4NbCommonBytes32(Diff32));
    Result := UInt32(PIn - PStart);
    Exit;
  end;
{$ENDIF}

  if (PIn < (PInLimit - 1)) and (PUInt16(PMatch)^ = PUInt16(PIn)^) then
  begin
    Inc(PIn, 2);
    Inc(PMatch, 2);
  end;
  if (PIn < PInLimit) and (PMatch^ = PIn^) then
    Inc(PIn);
  Result := UInt32(PIn - PStart);
end;

{ -------------------------------------------------------------------------
  Compression
  ------------------------------------------------------------------------- }

{ Emit the final tail of literals and return the total block size.
  On buffer-overflow this returns 0 (compression failed). }
function LZ4EmitLastLiterals(Op, OLimit, Anchor, IEnd, DstStart: PByte): Integer;
var
  LastRun, Accumulator: PtrUInt;
begin
  LastRun := PtrUInt(IEnd - Anchor);
  if (Op + LastRun + 1 + ((LastRun + 255 - RUN_MASK) div 255)) > OLimit then
    Exit(0);
  if LastRun >= RUN_MASK then
  begin
    Accumulator := LastRun - RUN_MASK;
    Op^ := RUN_MASK shl ML_BITS;
    Inc(Op);
    while Accumulator >= 255 do
    begin
      Op^ := 255;
      Inc(Op);
      Dec(Accumulator, 255);
    end;
    Op^ := Byte(Accumulator);
    Inc(Op);
  end
  else
  begin
    Op^ := Byte(LastRun shl ML_BITS);
    Inc(Op);
  end;
  if LastRun > 0 then
    Move(Anchor^, Op^, LastRun);
  Inc(Op, LastRun);
  Result := Integer(Op - DstStart);
end;

{ The main compression loop. Writes an LZ4 block to Dst and returns its size.
  If DstCapacity is less than CompressBound(SrcSize), the function may still
  succeed when the data compresses well; otherwise it returns 0 without
  writing a partial block. }
function LZ4CompressGeneric(Src, Dst: PByte; SrcSize, DstCapacity, Acceleration: Integer): Integer;
var
  HashTable: TLZ4HashTable;
  IP, Anchor, IEnd, MFLimitPlusOne, MatchLimit: PByte;
  Base: PByte;
  Op, OLimit, Token: PByte;
  ForwardH, H: UInt32;
  ForwardIP: PByte;
  Step, SearchMatchNb: Integer;
  MatchIndex, Current: UInt32;
  Match: PByte;
  LitLength, MatchCode: UInt32;
  Len: UInt32;
  TempLen: UInt32;
  MatchFound: Boolean;
begin
  Result := 0;

  if (SrcSize <= 0) or (SrcSize > LZ4_MAX_INPUT_SIZE) or (Src = nil) or (Dst = nil) then
    Exit;
  if DstCapacity < 1 then
    Exit;

  FillChar(HashTable, SizeOf(HashTable), 0);

  IP := Src;
  Anchor := Src;
  IEnd := Src + SrcSize;
  MFLimitPlusOne := IEnd - MFLIMIT + 1;
  MatchLimit := IEnd - LASTLITERALS;
  Base := Src;
  Op := Dst;
  OLimit := Op + DstCapacity;

  // Tiny blocks cannot host any match; emit all-literals.
  if SrcSize < LZ4_minLength then
  begin
    Result := LZ4EmitLastLiterals(Op, OLimit, Anchor, IEnd, Dst);
    Exit;
  end;

  // Seed the hash table with the first byte, then start the main loop
  // at IP+1 so catch-up has something to look back at.
  H := LZ4HashPosition(IP);
  HashTable[H] := UInt32(IP - Base);
  Inc(IP);
  ForwardH := LZ4HashPosition(IP);

  // Outer loop: each iteration emits exactly one (literals, match) sequence.
  while True do
  begin
    // ---- Find a match ----
    ForwardIP := IP;
    Step := 1;
    SearchMatchNb := Acceleration shl LZ4_skipTrigger;
    Match := nil; // silence "may be uninitialised"
    MatchFound := False;

    while not MatchFound do
    begin
      H := ForwardH;
      Current := UInt32(ForwardIP - Base);
      MatchIndex := HashTable[H];
      IP := ForwardIP;
      Inc(ForwardIP, Step);
      Step := SearchMatchNb shr LZ4_skipTrigger;
      Inc(SearchMatchNb);

      if ForwardIP > MFLimitPlusOne then
      begin
        // Out of scan space - flush remaining bytes as literals and exit.
        Result := LZ4EmitLastLiterals(Op, OLimit, Anchor, IEnd, Dst);
        Exit;
      end;

      Match := Base + MatchIndex;
      ForwardH := LZ4HashPosition(ForwardIP);
      HashTable[H] := Current;

      // A candidate is valid only if it's within LZ4_DISTANCE_MAX and the
      // next 4 bytes actually match.
      if (MatchIndex + LZ4_DISTANCE_MAX < Current) then
        Continue;
      if LZ4ReadU32(Match) = LZ4ReadU32(IP) then
        MatchFound := True;
    end;

    // ---- Catch up (extend match backwards) ----
    while (IP > Anchor) and (Match > Base) and (PByte(IP - 1)^ = PByte(Match - 1)^) do
    begin
      Dec(IP);
      Dec(Match);
    end;

    // ---- Encode literals ----
    LitLength := UInt32(IP - Anchor);
    Token := Op;
    Inc(Op);

    // Bounds check: literals + token + future offset + future end marker.
    if (Op + LitLength + (2 + 1 + LASTLITERALS) + (LitLength div 255)) > OLimit then
      Exit(0);

    if LitLength >= RUN_MASK then
    begin
      Len := LitLength - RUN_MASK;
      Token^ := RUN_MASK shl ML_BITS;
      while Len >= 255 do
      begin
        Op^ := 255;
        Inc(Op);
        Dec(Len, 255);
      end;
      Op^ := Byte(Len);
      Inc(Op);
    end
    else
      Token^ := Byte(LitLength shl ML_BITS);

    // Copy literals using Move (exact byte count, handles any alignment).
    if LitLength > 0 then
    begin
      Move(Anchor^, Op^, LitLength);
      Inc(Op, LitLength);
    end;

    // ---- Encode offset ----
    LZ4WriteU16LE(Op, UInt16(IP - Match));
    Inc(Op, 2);

    // ---- Encode match length ----
    MatchCode := LZ4Count(IP + MINMATCH, Match + MINMATCH, MatchLimit);
    Inc(IP, MatchCode + MINMATCH);

    if (Op + (1 + LASTLITERALS) + (MatchCode + 240) div 255) > OLimit then
      Exit(0);

    if MatchCode >= ML_MASK then
    begin
      Token^ := Token^ or ML_MASK;
      Dec(MatchCode, ML_MASK);
      while MatchCode >= 4 * 255 do
      begin
        PUInt32(Op)^ := $FFFFFFFF;
        Inc(Op, 4);
        Dec(MatchCode, 4 * 255);
      end;
      TempLen := MatchCode div 255;
      if TempLen > 0 then
      begin
        FillChar(Op^, TempLen, 255);
        Inc(Op, TempLen);
      end;
      Op^ := Byte(MatchCode mod 255);
      Inc(Op);
    end
    else
      Token^ := Token^ + Byte(MatchCode);

    Anchor := IP;

    // Done if we've reached the end-of-block parsing zone.
    if IP >= MFLimitPlusOne then
    begin
      Result := LZ4EmitLastLiterals(Op, OLimit, Anchor, IEnd, Dst);
      Exit;
    end;

    // Fill the hash table with the 2-bytes-ago position; helps find matches
    // that would be missed by the main stride.
    H := LZ4HashPosition(IP - 2);
    HashTable[H] := UInt32((IP - 2) - Base);

    // Resume scan from IP+1. (We skip the immediate-match optimization from
    // the reference C code to keep control flow linear.)
    Inc(IP);
    ForwardH := LZ4HashPosition(IP);
  end;
end;

{ -------------------------------------------------------------------------
  TLZ4 class methods
  ------------------------------------------------------------------------- }

class function TLZ4.CompressBound(InputSize: Integer): Integer;
begin
  if (InputSize <= 0) or (InputSize > LZ4_MAX_INPUT_SIZE) then
    Result := 0
  else
    Result := InputSize + (InputSize div 255) + 16;
end;

class function TLZ4.CompressFast(Src, Dst: Pointer; SrcSize, DstCapacity, Acceleration: Integer): Integer;
begin
  if Acceleration < 1 then
    Acceleration := LZ4_ACCELERATION_DEFAULT
  else if Acceleration > LZ4_ACCELERATION_MAX then
    Acceleration := LZ4_ACCELERATION_MAX;

  if SrcSize = 0 then
  begin
    // Empty input encodes as a single zero token (zero literals, no match).
    if (Dst = nil) or (DstCapacity < 1) then
      Exit(0);
    PByte(Dst)^ := 0;
    Exit(1);
  end;

  Result := LZ4CompressGeneric(PByte(Src), PByte(Dst), SrcSize, DstCapacity, Acceleration);
end;

class function TLZ4.Compress(Src, Dst: Pointer; SrcSize, DstCapacity: Integer): Integer;
begin
  Result := CompressFast(Src, Dst, SrcSize, DstCapacity, LZ4_ACCELERATION_DEFAULT);
end;

{ -------------------------------------------------------------------------
  Decompression
  ------------------------------------------------------------------------- }

{ Read the variable-length literal or match length extension.
  Returns True on success; False on truncation/corruption.
  We check "IP >= ILimit" BEFORE dereferencing to avoid OOB reads at the
  boundary (important when the last compressed byte would otherwise be
  consumed as a 255 continuation). }
function LZ4ReadVarLength(var IP: PByte; const ILimit: PByte; InitialCheck: Boolean;
  out LengthAdd: PtrUInt): Boolean;
var
  S: Byte;
begin
  LengthAdd := 0;
  if InitialCheck and (IP >= ILimit) then
    Exit(False);
  repeat
    if IP >= ILimit then
      Exit(False);
    S := IP^;
    Inc(IP);
    Inc(LengthAdd, S);
  until S <> 255;
  Result := True;
end;

{ Main safe decompression function. Internal; `LowPrefix` points at the
  oldest byte the decoder is allowed to read via back-references.
  For isolated blocks LowPrefix := Dst. For linked blocks (frame format
  with LZ4F_blockLinked), LowPrefix := Dst - PrefixSize. }
function LZ4DecompressInternal(Src, Dst: Pointer;
  CompressedSize, DstCapacity: Integer; LowPrefix: PByte): Integer;
var
  IP, IEnd: PByte;
  Op, OEnd, Cpy: PByte;
  Token: Byte;
  Length: PtrUInt;
  Offset: PtrUInt;
  Match: PByte;
  AddL: PtrUInt;
begin
  if (Src = nil) or (CompressedSize < 0) or (DstCapacity < 0) then
    Exit(-1);

  // Dst may be nil only when DstCapacity=0 (caller expects an empty result).
  if (Dst = nil) and (DstCapacity <> 0) then
    Exit(-1);

  IP := Src;
  IEnd := IP + CompressedSize;
  Op := Dst;
  OEnd := Op + DstCapacity;

  // Edge cases.
  if DstCapacity = 0 then
  begin
    if (CompressedSize = 1) and (IP^ = 0) then
      Exit(0);
    Exit(-1);
  end;
  if CompressedSize = 0 then
    Exit(-1);

  while True do
  begin
    if IP >= IEnd then
      Exit(-1);

    Token := IP^;
    Inc(IP);

    // ---- Literal length ----
    Length := Token shr ML_BITS;
    if Length = RUN_MASK then
    begin
      if not LZ4ReadVarLength(IP, IEnd, True, AddL) then
        Exit(-1);
      Inc(Length, AddL);
      // Overflow guards (defensive against crafted inputs).
      if (PtrUInt(Op) + Length) < PtrUInt(Op) then Exit(-1);
      if (PtrUInt(IP) + Length) < PtrUInt(IP) then Exit(-1);
    end;

    // ---- Copy literals ----
    Cpy := Op + Length;

    // Bounds-check both input and output before copying.
    if (IP + Length) > IEnd then
      Exit(-1);
    if Cpy > OEnd then
      Exit(-1);

    if Length > 0 then
      Move(IP^, Op^, Length);
    Inc(IP, Length);
    Op := Cpy;

    // If we've consumed the whole input, this was the final literal run.
    if IP = IEnd then
      Break;

    // ---- Offset ----
    if (IP + 2) > IEnd then
      Exit(-1);
    Offset := LZ4ReadU16LE(IP);
    Inc(IP, 2);
    if Offset = 0 then
      Exit(-1);
    // Guard against offsets that would wrap the pointer below LowPrefix.
    if Offset > PtrUInt(Op - LowPrefix) then
      Exit(-1);
    Match := Op - Offset;

    // ---- Match length ----
    Length := Token and ML_MASK;
    if Length = ML_MASK then
    begin
      if not LZ4ReadVarLength(IP, IEnd, False, AddL) then
        Exit(-1);
      Inc(Length, AddL);
      if (PtrUInt(Op) + Length) < PtrUInt(Op) then Exit(-1);
    end;
    Inc(Length, MINMATCH);

    // Defensive: match must fit in remaining output.
    if Length > PtrUInt(OEnd - Op) then
      Exit(-1);

    Cpy := Op + Length;

    // ---- Match copy ----
    // Always byte-by-byte. Simple, handles overlap (LZ77 pattern propagation)
    // correctly regardless of offset, no wildcopy overshoot concerns.
    while Op < Cpy do
    begin
      Op^ := Match^;
      Inc(Op);
      Inc(Match);
    end;
  end;

  Result := Integer(Op - PByte(Dst));
end;

class function TLZ4.Decompress(Src, Dst: Pointer; CompressedSize, DstCapacity: Integer): Integer;
begin
  Result := LZ4DecompressInternal(Src, Dst, CompressedSize, DstCapacity, PByte(Dst));
end;

class function TLZ4.DecompressWithPrefix(Src, Dst: Pointer;
  CompressedSize, DstCapacity, PrefixSize: Integer): Integer;
var
  LowPrefix: PByte;
begin
  if PrefixSize < 0 then Exit(-1);
  if PrefixSize > 65536 then Exit(-1);
  if (Dst = nil) and (PrefixSize <> 0) then Exit(-1);
  LowPrefix := PByte(Dst) - PrefixSize;
  Result := LZ4DecompressInternal(Src, Dst, CompressedSize, DstCapacity, LowPrefix);
end;

{ -------------------------------------------------------------------------
  TBytes / TStream convenience wrappers
  ------------------------------------------------------------------------- }

class function TLZ4.CompressBytes(const Source: TBytes; Acceleration: Integer): TBytes;
var
  SrcSize, MaxOut, Written: Integer;
  SrcPtr: Pointer;
begin
  SrcSize := Length(Source);
  MaxOut := CompressBound(SrcSize);
  if MaxOut = 0 then
  begin
    if SrcSize = 0 then
    begin
      // Encode an empty block as a single zero token.
      SetLength(Result, 1);
      Result[0] := 0;
      Exit;
    end;
    raise ELZ4Error.CreateFmt('Input size out of range: %d', [SrcSize]);
  end;
  SetLength(Result, MaxOut);
  if SrcSize = 0 then
    SrcPtr := nil
  else
    SrcPtr := @Source[0];
  Written := CompressFast(SrcPtr, @Result[0], SrcSize, MaxOut, Acceleration);
  if Written <= 0 then
    raise ELZ4Error.Create('LZ4 compression failed');
  SetLength(Result, Written);
end;

class function TLZ4.DecompressBytes(const Source: TBytes; OriginalSize: Integer): TBytes;
var
  Decoded: Integer;
  SrcPtr: Pointer;
begin
  if OriginalSize < 0 then
    raise ELZ4Error.Create('OriginalSize must be >= 0');
  SetLength(Result, OriginalSize);
  if Length(Source) = 0 then
  begin
    if OriginalSize = 0 then Exit;
    raise ELZ4Error.Create('Empty compressed input');
  end;
  SrcPtr := @Source[0];
  if OriginalSize = 0 then
  begin
    Decoded := Decompress(SrcPtr, nil, Length(Source), 0);
    if Decoded < 0 then
      raise ELZ4Error.CreateFmt('LZ4 decompression error (%d)', [Decoded]);
    Exit;
  end;
  Decoded := Decompress(SrcPtr, @Result[0], Length(Source), OriginalSize);
  if Decoded < 0 then
    raise ELZ4Error.CreateFmt('LZ4 decompression error (%d)', [Decoded]);
  SetLength(Result, Decoded);
end;

class function TLZ4.CompressStream(InStream, OutStream: TStream; Acceleration: Integer): Int64;
var
  SrcSize: Int64;
  Src, Dst: TBytes;
  SizeLE: UInt32;
  MaxOut, Written: Integer;
begin
  SrcSize := InStream.Size - InStream.Position;
  if SrcSize > LZ4_MAX_INPUT_SIZE then
    raise ELZ4Error.CreateFmt('Input stream too large: %d bytes (max %d)', [SrcSize, LZ4_MAX_INPUT_SIZE]);

  SetLength(Src, SrcSize);
  if SrcSize > 0 then
    InStream.ReadBuffer(Src[0], SrcSize);

  MaxOut := CompressBound(Integer(SrcSize));
  if MaxOut = 0 then MaxOut := 1;  // only when SrcSize = 0
  SetLength(Dst, MaxOut);

  if SrcSize = 0 then
    Written := 0
  else
  begin
    Written := CompressFast(@Src[0], @Dst[0], Integer(SrcSize), MaxOut, Acceleration);
    if Written <= 0 then
      raise ELZ4Error.Create('LZ4 compression failed');
  end;

  SizeLE := UInt32(SrcSize);
  OutStream.WriteBuffer(SizeLE, SizeOf(SizeLE));
  if Written > 0 then
    OutStream.WriteBuffer(Dst[0], Written);

  Result := Int64(SizeOf(SizeLE)) + Written;
end;

class function TLZ4.DecompressStream(InStream, OutStream: TStream): Int64;
var
  SizeLE: UInt32;
  OrigSize: Integer;
  Remaining: Int64;
  Src, Dst: TBytes;
  Decoded: Integer;
begin
  InStream.ReadBuffer(SizeLE, SizeOf(SizeLE));
  OrigSize := Integer(SizeLE);
  if OrigSize < 0 then
    raise ELZ4Error.Create('Invalid LZ4 stream (negative size)');

  Remaining := InStream.Size - InStream.Position;
  SetLength(Src, Remaining);
  if Remaining > 0 then
    InStream.ReadBuffer(Src[0], Remaining);

  if OrigSize = 0 then
  begin
    Result := 0;
    Exit;
  end;

  SetLength(Dst, OrigSize);
  if Length(Src) = 0 then
    raise ELZ4Error.Create('LZ4 stream truncated: no compressed payload');

  Decoded := Decompress(@Src[0], @Dst[0], Length(Src), OrigSize);
  if Decoded < 0 then
    raise ELZ4Error.CreateFmt('LZ4 decompression error (%d)', [Decoded]);
  if Decoded <> OrigSize then
    raise ELZ4Error.CreateFmt('LZ4 size mismatch: expected %d, got %d', [OrigSize, Decoded]);

  OutStream.WriteBuffer(Dst[0], Decoded);
  Result := Decoded;
end;

{ -------------------------------------------------------------------------
  Free-standing aliases
  ------------------------------------------------------------------------- }

function LZ4CompressBound(InputSize: Integer): Integer;
begin
  Result := TLZ4.CompressBound(InputSize);
end;

function LZ4Compress(Src, Dst: Pointer; SrcSize, DstCapacity: Integer): Integer;
begin
  Result := TLZ4.Compress(Src, Dst, SrcSize, DstCapacity);
end;

function LZ4CompressFast(Src, Dst: Pointer; SrcSize, DstCapacity, Acceleration: Integer): Integer;
begin
  Result := TLZ4.CompressFast(Src, Dst, SrcSize, DstCapacity, Acceleration);
end;

function LZ4Decompress(Src, Dst: Pointer; CompressedSize, DstCapacity: Integer): Integer;
begin
  Result := TLZ4.Decompress(Src, Dst, CompressedSize, DstCapacity);
end;

end.
