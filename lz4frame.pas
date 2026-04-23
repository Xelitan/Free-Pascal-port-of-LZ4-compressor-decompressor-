{
  lz4frame.pas - LZ4 frame format (the standard .lz4 file format).

  This unit implements the LZ4 frame format v1.6.3 as specified at
    https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md
  Files produced here are compatible with the `lz4` CLI tool and liblz4.

  Frame layout:
    [4 bytes]  Magic number: 0x184D2204 (little-endian)
    [1 byte]   FLG (flags)
    [1 byte]   BD  (block descriptor)
    [8 bytes]  Optional content size (present iff FLG.ContentSize)
    [4 bytes]  Optional dictionary ID  (present iff FLG.DictID) - NOT SUPPORTED
    [1 byte]   Header checksum: byte 2 of XXH32(FLG..DictID, 0)
    [...]      Data blocks:
                 [4 bytes]  Block size, bit 31 = "uncompressed" flag
                 [N bytes]  Block data (raw or LZ4-compressed)
                 [4 bytes]  Optional block checksum (XXH32, iff FLG.BlockChecksum)
    [4 bytes]  End mark: 0x00000000
    [4 bytes]  Optional content checksum XXH32 (iff FLG.ContentChecksum)

  Copyright (c) 2011-2023, Yann Collet (reference C implementation).
  Pascal port licensed under the same terms (BSD 2-Clause).
}
unit lz4frame;

{$mode objfpc}{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, Classes, lz4, xxHash;

const
  LZ4F_VERSION             = 100;
  LZ4F_MAGIC               = UInt32($184D2204);
  LZ4F_SKIPPABLE_MAGIC_MIN = UInt32($184D2A50);
  LZ4F_SKIPPABLE_MAGIC_MAX = UInt32($184D2A5F);

type
  ELZ4FrameError = class(ELZ4Error);

  { Block max size. These map 1:1 to BD byte codes 4..7. }
  TLZ4BlockSize = (lbs64KB, lbs256KB, lbs1MB, lbs4MB);

  TLZ4FrameOptions = record
    BlockSize:          TLZ4BlockSize; // Max uncompressed block size
    BlockIndependence:  Boolean;       // True = blocks don't reference each other
    ContentChecksum:    Boolean;       // Append XXH32 of uncompressed content
    BlockChecksum:      Boolean;       // Append XXH32 after each block
    IncludeContentSize: Boolean;       // Embed total size in frame header
    Acceleration:       Integer;       // Pass-through to TLZ4.CompressFast
  end;

  TLZ4Frame = class
  public
    { Sane defaults: 64 KB blocks, independent, content checksum on,
      no block checksum, no content size, default acceleration. }
    class function DefaultOptions: TLZ4FrameOptions; static;

    { Compress InStream -> OutStream from current positions. Reads the
      remainder of InStream. Returns bytes written to OutStream. }
    class function CompressStream(InStream, OutStream: TStream;
      const Options: TLZ4FrameOptions): Int64; overload; static;
    class function CompressStream(InStream, OutStream: TStream): Int64;
      overload; static;

    { Decompress InStream -> OutStream. Consumes exactly one frame
      (magic..end-mark..optional-checksum). Returns bytes written. }
    class function DecompressStream(InStream, OutStream: TStream): Int64; static;

    { Full-buffer convenience wrappers. }
    class function CompressBytes(const Source: TBytes;
      const Options: TLZ4FrameOptions): TBytes; overload; static;
    class function CompressBytes(const Source: TBytes): TBytes; overload; static;
    class function DecompressBytes(const Source: TBytes): TBytes; static;

    { File convenience wrappers. }
    class procedure CompressFile(const InName, OutName: string;
      const Options: TLZ4FrameOptions); overload; static;
    class procedure CompressFile(const InName, OutName: string);
      overload; static;
    class procedure DecompressFile(const InName, OutName: string); static;
  end;

implementation

const
  // FLG byte bits
  LZ4F_FLG_VERSION      = $40; // bits 7-6 = 01 (version 1)
  LZ4F_FLG_VERSION_MASK = $C0;
  LZ4F_FLG_BLOCK_INDEP  = $20; // bit 5
  LZ4F_FLG_BLOCK_CKSUM  = $10; // bit 4
  LZ4F_FLG_CONTENT_SIZE = $08; // bit 3
  LZ4F_FLG_CONT_CKSUM   = $04; // bit 2
  LZ4F_FLG_RESERVED     = $02; // bit 1 - must be 0
  LZ4F_FLG_DICT_ID      = $01; // bit 0

  // BD byte bits
  LZ4F_BD_RESERVED_MASK = $8F; // bits 7,3-0 must be 0
  LZ4F_BD_BSIZE_SHIFT   = 4;

  // Block header
  LZ4F_BLOCK_UNCOMPRESSED = UInt32($80000000);
  LZ4F_BLOCK_SIZE_MASK    = UInt32($7FFFFFFF);

  // Linked-block history window (LZ4 max back-reference distance)
  LZ4F_DICT_SIZE = 64 * 1024;

{ -------------------------------------------------------------------------
  Low-level helpers
  ------------------------------------------------------------------------- }

function BlockMaxBytes(Bs: TLZ4BlockSize): Integer; inline;
begin
  case Bs of
    lbs64KB:  Result := 64 * 1024;
    lbs256KB: Result := 256 * 1024;
    lbs1MB:   Result := 1024 * 1024;
    lbs4MB:   Result := 4 * 1024 * 1024;
  else
    Result := 64 * 1024;
  end;
end;

function BlockSizeCodeToMax(Code: Integer): Integer; inline;
begin
  case Code of
    4: Result := 64 * 1024;
    5: Result := 256 * 1024;
    6: Result := 1024 * 1024;
    7: Result := 4 * 1024 * 1024;
  else
    Result := -1;
  end;
end;

procedure WriteU32LE(Stream: TStream; Value: UInt32);
var
  B: array[0..3] of Byte;
begin
  B[0] := Byte(Value);
  B[1] := Byte(Value shr 8);
  B[2] := Byte(Value shr 16);
  B[3] := Byte(Value shr 24);
  Stream.WriteBuffer(B[0], 4);
end;

function ReadU32LE(Stream: TStream): UInt32;
var
  B: array[0..3] of Byte;
begin
  Stream.ReadBuffer(B[0], 4);
  Result := UInt32(B[0]) or (UInt32(B[1]) shl 8) or
            (UInt32(B[2]) shl 16) or (UInt32(B[3]) shl 24);
end;

function TryReadU32LE(Stream: TStream; out Value: UInt32): Boolean;
var
  B: array[0..3] of Byte;
  Got: Integer;
begin
  Got := Stream.Read(B[0], 4);
  if Got <> 4 then Exit(False);
  Value := UInt32(B[0]) or (UInt32(B[1]) shl 8) or
           (UInt32(B[2]) shl 16) or (UInt32(B[3]) shl 24);
  Result := True;
end;

procedure Encode64LE(Value: UInt64; Dst: PByte); inline;
var
  I: Integer;
begin
  for I := 0 to 7 do
  begin
    Dst[I] := Byte(Value);
    Value := Value shr 8;
  end;
end;

{ -------------------------------------------------------------------------
  TLZ4Frame
  ------------------------------------------------------------------------- }

class function TLZ4Frame.DefaultOptions: TLZ4FrameOptions;
begin
  Result.BlockSize          := lbs64KB;
  Result.BlockIndependence  := True;
  Result.ContentChecksum    := True;
  Result.BlockChecksum      := False;
  Result.IncludeContentSize := False;
  Result.Acceleration       := LZ4_ACCELERATION_DEFAULT;
end;

class function TLZ4Frame.CompressStream(InStream, OutStream: TStream;
  const Options: TLZ4FrameOptions): Int64;
var
  InBuf, OutBuf: TBytes;
  BlockMax, MaxCompressed: Integer;
  Flg, Bd: Byte;
  HeaderBytes: array[0..9] of Byte;  // FLG+BD (2) + optional 8-byte CS
  HeaderLen: Integer;
  HeaderChecksum: Byte;
  BytesRead, CompressedSize: Integer;
  ContentState: pXXH32_state_t;
  UseContentSize: Boolean;
  ContentSize: UInt64;
  InStart, OutStart: Int64;
  BlockHdr: UInt32;
  StoreRaw: Boolean;
begin
  if Options.Acceleration < 1 then
    raise ELZ4FrameError.Create('Acceleration must be >= 1');

  BlockMax := BlockMaxBytes(Options.BlockSize);
  MaxCompressed := TLZ4.CompressBound(BlockMax);
  if MaxCompressed <= 0 then
    raise ELZ4FrameError.Create('Internal: bad CompressBound');

  SetLength(InBuf, BlockMax);
  SetLength(OutBuf, MaxCompressed);

  OutStart := OutStream.Position;
  InStart := InStream.Position;

  UseContentSize := Options.IncludeContentSize;
  ContentSize := 0;
  if UseContentSize then
  begin
    try
      ContentSize := UInt64(InStream.Size - InStart);
    except
      UseContentSize := False;
    end;
  end;

  // Build frame descriptor
  Flg := LZ4F_FLG_VERSION;
  if Options.BlockIndependence then Flg := Flg or LZ4F_FLG_BLOCK_INDEP;
  if Options.BlockChecksum     then Flg := Flg or LZ4F_FLG_BLOCK_CKSUM;
  if UseContentSize            then Flg := Flg or LZ4F_FLG_CONTENT_SIZE;
  if Options.ContentChecksum   then Flg := Flg or LZ4F_FLG_CONT_CKSUM;

  Bd := Byte(Byte(Ord(Options.BlockSize) + 4) shl LZ4F_BD_BSIZE_SHIFT);

  HeaderBytes[0] := Flg;
  HeaderBytes[1] := Bd;
  HeaderLen := 2;
  if UseContentSize then
  begin
    Encode64LE(ContentSize, @HeaderBytes[HeaderLen]);
    Inc(HeaderLen, 8);
  end;

  // Header checksum = byte 2 of XXH32 hash
  HeaderChecksum := Byte((XXH32(@HeaderBytes[0], HeaderLen, 0) shr 8) and $FF);

  // Emit header
  WriteU32LE(OutStream, LZ4F_MAGIC);
  OutStream.WriteBuffer(HeaderBytes[0], HeaderLen);
  OutStream.WriteBuffer(HeaderChecksum, 1);

  // Streaming content hash
  ContentState := nil;
  if Options.ContentChecksum then
  begin
    ContentState := XXH32_createState();
    if ContentState = nil then
      raise ELZ4FrameError.Create('XXH32_createState failed');
    XXH32_reset(ContentState, 0);
  end;

  try
    // Data blocks
    while True do
    begin
      BytesRead := InStream.Read(InBuf[0], BlockMax);
      if BytesRead <= 0 then Break;

      if Options.ContentChecksum then
        XXH32_update(ContentState, @InBuf[0], BytesRead);

      // Try to compress; fall back to raw storage if compression didn't help.
      CompressedSize := TLZ4.CompressFast(@InBuf[0], @OutBuf[0],
        BytesRead, MaxCompressed, Options.Acceleration);

      StoreRaw := (CompressedSize <= 0) or (CompressedSize >= BytesRead);
      if StoreRaw then
      begin
        BlockHdr := UInt32(BytesRead) or LZ4F_BLOCK_UNCOMPRESSED;
        WriteU32LE(OutStream, BlockHdr);
        OutStream.WriteBuffer(InBuf[0], BytesRead);
        if Options.BlockChecksum then
          WriteU32LE(OutStream, XXH32(@InBuf[0], BytesRead, 0));
      end
      else
      begin
        BlockHdr := UInt32(CompressedSize);
        WriteU32LE(OutStream, BlockHdr);
        OutStream.WriteBuffer(OutBuf[0], CompressedSize);
        if Options.BlockChecksum then
          WriteU32LE(OutStream, XXH32(@OutBuf[0], CompressedSize, 0));
      end;
    end;

    // End mark
    WriteU32LE(OutStream, 0);

    // Content checksum
    if Options.ContentChecksum then
      WriteU32LE(OutStream, XXH32_digest(ContentState));
  finally
    if ContentState <> nil then
      XXH32_freeState(ContentState);
  end;

  Result := OutStream.Position - OutStart;
end;

class function TLZ4Frame.CompressStream(InStream, OutStream: TStream): Int64;
begin
  Result := CompressStream(InStream, OutStream, DefaultOptions);
end;

class function TLZ4Frame.DecompressStream(InStream, OutStream: TStream): Int64;
var
  Magic, BlockHdr: UInt32;
  Flg, Bd, StoredHC, ComputedHC: Byte;
  Version, BlockSizeCode: Integer;
  BlockIndep, BlockChecksum, HasContentSize, ContentChecksum, HasDictID: Boolean;
  BlockMax: Integer;
  HeaderBytes: array[0..13] of Byte;
  HeaderLen: Integer;
  BlockSize: Integer;
  Uncompressed: Boolean;
  InBuf, OutBuf: TBytes;
  InBufSize: Integer;
  Decoded: Integer;
  StoredBlockChk: UInt32;
  ContentState: pXXH32_state_t;
  StoredContentChk: UInt32;
  OutStart: Int64;
  HistSize: Integer;
  I: Integer;
begin
  OutStart := OutStream.Position;

  if not TryReadU32LE(InStream, Magic) then
    raise ELZ4FrameError.Create('Unexpected end of stream reading magic');
  if (Magic >= LZ4F_SKIPPABLE_MAGIC_MIN) and (Magic <= LZ4F_SKIPPABLE_MAGIC_MAX) then
    raise ELZ4FrameError.Create('Skippable frames are not supported');
  if Magic <> LZ4F_MAGIC then
    raise ELZ4FrameError.CreateFmt('Not an LZ4 frame (magic=$%.8x)', [Magic]);

  InStream.ReadBuffer(Flg, 1);
  InStream.ReadBuffer(Bd, 1);
  HeaderBytes[0] := Flg;
  HeaderBytes[1] := Bd;
  HeaderLen := 2;

  Version := (Flg and LZ4F_FLG_VERSION_MASK) shr 6;
  if Version <> 1 then
    raise ELZ4FrameError.CreateFmt('Unsupported frame version: %d', [Version]);
  if (Flg and LZ4F_FLG_RESERVED) <> 0 then
    raise ELZ4FrameError.Create('Reserved bit set in FLG');

  BlockIndep      := (Flg and LZ4F_FLG_BLOCK_INDEP)  <> 0;
  BlockChecksum   := (Flg and LZ4F_FLG_BLOCK_CKSUM)  <> 0;
  HasContentSize  := (Flg and LZ4F_FLG_CONTENT_SIZE) <> 0;
  ContentChecksum := (Flg and LZ4F_FLG_CONT_CKSUM)   <> 0;
  HasDictID       := (Flg and LZ4F_FLG_DICT_ID)      <> 0;

  if (Bd and LZ4F_BD_RESERVED_MASK) <> 0 then
    raise ELZ4FrameError.Create('Reserved bits set in BD');

  BlockSizeCode := (Bd shr LZ4F_BD_BSIZE_SHIFT) and 7;
  BlockMax := BlockSizeCodeToMax(BlockSizeCode);
  if BlockMax < 0 then
    raise ELZ4FrameError.CreateFmt('Invalid block size code: %d', [BlockSizeCode]);

  if HasContentSize then
  begin
    for I := 0 to 7 do
    begin
      InStream.ReadBuffer(HeaderBytes[HeaderLen], 1);
      Inc(HeaderLen);
    end;
    // We don't need the value itself, just the bytes for the header checksum.
  end;

  if HasDictID then
    raise ELZ4FrameError.Create('Dictionary IDs are not supported');

  InStream.ReadBuffer(StoredHC, 1);
  ComputedHC := Byte((XXH32(@HeaderBytes[0], HeaderLen, 0) shr 8) and $FF);
  if StoredHC <> ComputedHC then
    raise ELZ4FrameError.Create('Header checksum mismatch');

  InBufSize := TLZ4.CompressBound(BlockMax);
  if InBufSize < BlockMax then InBufSize := BlockMax;
  SetLength(InBuf, InBufSize);

  // For linked blocks, OutBuf acts as a sliding window:
  //   Buf[0 .. HistSize-1]                = up to 64 KB of previous output
  //   Buf[HistSize .. HistSize+BlockMax-1] = scratch space for the next block
  // For independent blocks we still use the same layout but HistSize stays 0.
  SetLength(OutBuf, LZ4F_DICT_SIZE + BlockMax);
  HistSize := 0;

  ContentState := nil;
  if ContentChecksum then
  begin
    ContentState := XXH32_createState();
    if ContentState = nil then
      raise ELZ4FrameError.Create('XXH32_createState failed');
    XXH32_reset(ContentState, 0);
  end;

  try
    while True do
    begin
      BlockHdr := ReadU32LE(InStream);
      if BlockHdr = 0 then Break;  // End mark

      Uncompressed := (BlockHdr and LZ4F_BLOCK_UNCOMPRESSED) <> 0;
      BlockSize := Integer(BlockHdr and LZ4F_BLOCK_SIZE_MASK);
      if BlockSize <= 0 then
        raise ELZ4FrameError.Create('Invalid block size');
      if BlockSize > InBufSize then
        raise ELZ4FrameError.CreateFmt('Block size exceeds limit: %d', [BlockSize]);

      InStream.ReadBuffer(InBuf[0], BlockSize);

      if BlockChecksum then
      begin
        StoredBlockChk := ReadU32LE(InStream);
        if XXH32(@InBuf[0], BlockSize, 0) <> StoredBlockChk then
          raise ELZ4FrameError.Create('Block checksum mismatch');
      end;

      if Uncompressed then
      begin
        if BlockSize > BlockMax then
          raise ELZ4FrameError.Create('Uncompressed block exceeds block max');
        Move(InBuf[0], OutBuf[HistSize], BlockSize);
        Decoded := BlockSize;
      end
      else
      begin
        if BlockIndep then
          Decoded := TLZ4.Decompress(@InBuf[0], @OutBuf[HistSize],
            BlockSize, BlockMax)
        else
          Decoded := TLZ4.DecompressWithPrefix(@InBuf[0], @OutBuf[HistSize],
            BlockSize, BlockMax, HistSize);
        if Decoded < 0 then
          raise ELZ4FrameError.CreateFmt('Block decompression error (%d)', [Decoded]);
      end;

      if Decoded > 0 then
      begin
        OutStream.WriteBuffer(OutBuf[HistSize], Decoded);
        if ContentChecksum then
          XXH32_update(ContentState, @OutBuf[HistSize], Decoded);
      end;

      // Advance the sliding window. Keep at most 64 KB of history so the
      // next block's back-references can still reach it.
      Inc(HistSize, Decoded);
      if HistSize > LZ4F_DICT_SIZE then
      begin
        Move(OutBuf[HistSize - LZ4F_DICT_SIZE], OutBuf[0], LZ4F_DICT_SIZE);
        HistSize := LZ4F_DICT_SIZE;
      end;
    end;

    if ContentChecksum then
    begin
      StoredContentChk := ReadU32LE(InStream);
      if XXH32_digest(ContentState) <> StoredContentChk then
        raise ELZ4FrameError.Create('Content checksum mismatch');
    end;
  finally
    if ContentState <> nil then
      XXH32_freeState(ContentState);
  end;

  Result := OutStream.Position - OutStart;
end;

class function TLZ4Frame.CompressBytes(const Source: TBytes;
  const Options: TLZ4FrameOptions): TBytes;
var
  InStream, OutStream: TMemoryStream;
begin
  InStream := TMemoryStream.Create;
  OutStream := TMemoryStream.Create;
  try
    if Length(Source) > 0 then
      InStream.WriteBuffer(Source[0], Length(Source));
    InStream.Position := 0;
    CompressStream(InStream, OutStream, Options);
    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Result[0], OutStream.Size);
    end;
  finally
    InStream.Free;
    OutStream.Free;
  end;
end;

class function TLZ4Frame.CompressBytes(const Source: TBytes): TBytes;
begin
  Result := CompressBytes(Source, DefaultOptions);
end;

class function TLZ4Frame.DecompressBytes(const Source: TBytes): TBytes;
var
  InStream, OutStream: TMemoryStream;
begin
  if Length(Source) = 0 then
    raise ELZ4FrameError.Create('Empty frame');
  InStream := TMemoryStream.Create;
  OutStream := TMemoryStream.Create;
  try
    InStream.WriteBuffer(Source[0], Length(Source));
    InStream.Position := 0;
    DecompressStream(InStream, OutStream);
    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Result[0], OutStream.Size);
    end;
  finally
    InStream.Free;
    OutStream.Free;
  end;
end;

class procedure TLZ4Frame.CompressFile(const InName, OutName: string;
  const Options: TLZ4FrameOptions);
var
  InFS, OutFS: TFileStream;
begin
  InFS := TFileStream.Create(InName, fmOpenRead or fmShareDenyWrite);
  try
    OutFS := TFileStream.Create(OutName, fmCreate);
    try
      CompressStream(InFS, OutFS, Options);
    finally
      OutFS.Free;
    end;
  finally
    InFS.Free;
  end;
end;

class procedure TLZ4Frame.CompressFile(const InName, OutName: string);
var
  Opts: TLZ4FrameOptions;
begin
  Opts := DefaultOptions;
  Opts.IncludeContentSize := True;  // handy when writing files
  CompressFile(InName, OutName, Opts);
end;

class procedure TLZ4Frame.DecompressFile(const InName, OutName: string);
var
  InFS, OutFS: TFileStream;
begin
  InFS := TFileStream.Create(InName, fmOpenRead or fmShareDenyWrite);
  try
    OutFS := TFileStream.Create(OutName, fmCreate);
    try
      DecompressStream(InFS, OutFS);
    finally
      OutFS.Free;
    end;
  finally
    InFS.Free;
  end;
end;

end.
