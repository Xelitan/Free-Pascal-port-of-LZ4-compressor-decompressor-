unit LZ4Simple;

//Pascal port of LZ4
//Port by www.xelitan.com
//License: BSD 2-Clause

interface

uses Classes, SysUtils, LZ4Frame;

function CompressStreams(Infile, Outfile: TStream): Integer;
function DecompressStreams(Infile, Outfile: TStream): Integer;

function CompressFile(Infilename, Outfilename: String): Integer;
function DecompressFile(Infilename, Outfilename: String): Integer;

function LZ4(Uncompressed: AnsiString): AnsiString;
function UnLZ4(Compressed: AnsiString): AnsiString;

implementation

function CompressStreams(Infile, Outfile: TStream): Integer;
begin
  Result := TLZ4Frame.CompressStream(Infile, Outfile);
end;

function DecompressStreams(Infile, Outfile: TStream): Integer;
begin
  Result := TLZ4Frame.DecompressStream(Infile, Outfile);
end;

function CompressFile(Infilename, Outfilename: String): Integer;
var
  InFile: TFileStream;
  OutFile: TFileStream;
begin
  Result := 0;
  InFile := nil;
  OutFile := nil;

  try
    try
      InFile := TFileStream.Create(Infilename, fmOpenRead or fmShareDenyWrite);
    except
      Result := -1;
      Exit;
    end;

    try
      try
        OutFile := TFileStream.Create(Outfilename, fmCreate);
      except
        Result := -3;
        Exit;
      end;

      Result := CompressStreams(InFile, OutFile);
    finally
      OutFile.Free;
    end;
  finally
    InFile.Free;
  end;
end;

function DecompressFile(Infilename, Outfilename: String): Integer;
var
  InFile: TFileStream;
  OutFile: TFileStream;
begin
  Result := 0;
  InFile := nil;
  OutFile := nil;

  try
    try
      InFile := TFileStream.Create(Infilename, fmOpenRead or fmShareDenyWrite);
    except
      Result := -1;
      Exit;
    end;

    try
      try
        OutFile := TFileStream.Create(Outfilename, fmCreate);
      except
        Result := -3;
        Exit;
      end;

      Result := DecompressStreams(InFile, OutFile);
    finally
      OutFile.Free;
    end;
  finally
    InFile.Free;
  end;
end;

function LZ4(Uncompressed: AnsiString): AnsiString;
var
  InStream, OutStream: TMemoryStream;
begin
  Result := '';
  InStream := TMemoryStream.Create;
  OutStream := TMemoryStream.Create;
  try
    // put data in a stream
    if Length(Uncompressed) > 0 then
      InStream.WriteBuffer(Pointer(Uncompressed)^, Length(Uncompressed));
    InStream.Position := 0;

    // pack
    if CompressStreams(InStream, OutStream) <> 0 then
      Exit;

    // stream to string
    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Pointer(Result)^, OutStream.Size);
    end;
  finally
    OutStream.Free;
    InStream.Free;
  end;
end;

function UnLZ4(Compressed: AnsiString): AnsiString;
var
  InStream, OutStream: TMemoryStream;
begin
  Result := '';
  InStream := TMemoryStream.Create;
  OutStream := TMemoryStream.Create;
  try
    // string to stream
    if Length(Compressed) > 0 then
      InStream.WriteBuffer(Pointer(Compressed)^, Length(Compressed));
    InStream.Position := 0;

    // unpack
    if DecompressStreams(InStream, OutStream) <> 0 then
      Exit;

    // stream to string
    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Pointer(Result)^, OutStream.Size);
    end;
  finally
    OutStream.Free;
    InStream.Free;
  end;
end;

end.
