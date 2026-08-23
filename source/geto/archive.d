module geto.archive;

import std.array : appender;
import std.range : only;

import squiz_box;

/// Raised when an archive or compressed stream cannot be read.
class ArchiveException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/// One member of a tar or zip archive.
struct ArchiveEntry
{
    string path;
    ubyte[] data;
    string linkTarget;
    bool isSymlink;
}

private ubyte[] collect(R)(R chunks)
{
    auto output = appender!(ubyte[]);
    foreach (chunk; chunks)
        output ~= chunk;
    return output.data;
}

/// Decompresses a gzip stream, also reporting the filename its header carries.
ubyte[] gunzip(ubyte[] data, out string storedName)
{
    string captured;
    void onHeader(GzHeader header) @safe
    {
        captured = header.filename;
    }

    try
    {
        auto result = collect(only(data).inflateGz(&onHeader));
        storedName = captured;
        return result;
    }
    catch (Exception failure)
        throw new ArchiveException("gzip: " ~ failure.msg);
}

ubyte[] unxz(ubyte[] data)
{
    try
        return collect(only(data).decompressXz());
    catch (Exception failure)
        throw new ArchiveException("xz: " ~ failure.msg);
}

ubyte[] unbzip2(ubyte[] data)
{
    try
        return collect(only(data).decompressBzip2());
    catch (Exception failure)
        throw new ArchiveException("bzip2: " ~ failure.msg);
}

ubyte[] unzstd(ubyte[] data)
{
    try
        return collect(only(data).decompressZstd());
    catch (Exception failure)
        throw new ArchiveException("zstd: " ~ failure.msg);
}

private ArchiveEntry[] readEntries(R)(R entries)
{
    ArchiveEntry[] result;
    foreach (entry; entries)
    {
        final switch (entry.type)
        {
        case EntryType.directory:
            continue;
        case EntryType.symlink:
            result ~= ArchiveEntry(entry.path, null, entry.linkname, true);
            continue;
        case EntryType.regular:
            result ~= ArchiveEntry(entry.path, entry.readContent(), null, false);
            continue;
        }
    }
    return result;
}

/// Reads every regular file and symlink out of an uncompressed tar stream.
ArchiveEntry[] readTar(ubyte[] data)
{
    try
        return readEntries(only(data).unboxTar());
    catch (Exception failure)
        throw new ArchiveException("tar: " ~ failure.msg);
}

/// Reads every regular file and symlink out of a zip archive.
ArchiveEntry[] readZip(ubyte[] data)
{
    try
        return readEntries(unboxZip(data));
    catch (Exception failure)
        throw new ArchiveException("zip: " ~ failure.msg);
}

unittest
{
    import std.datetime : SysTime;
    import std.string : representation;

    auto payload = cast(ubyte[]) "hello squiz".dup;
    auto gz = collect(only(payload).deflateGz());
    string name;
    assert(gunzip(gz, name) == payload);

    import std.range.interfaces : inputRangeObject;

    auto tarball = collect(only(cast(BoxEntry) new InfoBoxEntry(BoxEntryInfo("greeting.txt",
            EntryType.regular, null, payload.length, SysTime.init, octalAttributes),
            inputRangeObject(only(cast(const(ubyte)[]) payload)))).boxTar());
    auto entries = readTar(tarball);
    assert(entries.length == 1);
    assert(entries[0].path == "greeting.txt");
    assert(entries[0].data == payload);
}

version (unittest) private uint octalAttributes()
{
    import std.conv : octal;

    return octal!"100644";
}
