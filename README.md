# lz4 — Free Pascal Port

LZ4 compression algorithm ported to Free Pascal.

Based on the C reference implementation (v 1.10.0) form https://github.com/lz4/lz4

## Using as a library

Add Lz4Simple.pas to your uses

```
function LZ4(Uncompressed: AnsiString): AnsiString;
function UnLZ4(Compressed: AnsiString): AnsiString;
function CompressFile(Infilename, Outfilename: String): Integer;
function DecompressFile(Infilename, Outfilename: String): Integer;
function CompressStreams(Infile, Outfile: TStream): Integer;
function DecompressStreams(Infile, Outfile: TStream): Integer;
```

## License

BSD-2
