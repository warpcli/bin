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
///
/// This is hand-rolled rather than delegated because squiz-box rejects PAX
/// extended headers outright, and they are everywhere: GNU and BSD tar emit
/// them for long paths, large files and high uids. Half the entries in a
/// micromamba release are `././@PaxHeader`.
ArchiveEntry[] readTar(ubyte[] data)
{
    enum blockSize = 512;

    // Numeric fields are octal, space or NUL padded. GNU switches to base-256
    // with the high bit set once a value no longer fits.
    static ulong parseNumber(const(ubyte)[] field)
    {
        if (field.length == 0)
            return 0;
        if (field[0] & 0x80)
        {
            ulong value = cast(ulong)(field[0] & 0x7F);
            foreach (b; field[1 .. $])
                value = (value << 8) | b;
            return value;
        }
        ulong value = 0;
        foreach (b; field)
        {
            if (b == ' ' || b == 0)
                continue;
            if (b < '0' || b > '7')
                break;
            value = value * 8 + (b - '0');
        }
        return value;
    }

    static string trimmed(const(ubyte)[] field)
    {
        size_t end = 0;
        while (end < field.length && field[end] != 0)
            end++;
        return cast(string) field[0 .. end].idup;
    }

    /// PAX records are "<len> <key>=<value>\n", with len covering the whole
    /// record including its own digits.
    static string[string] parsePax(const(ubyte)[] body_)
    {
        string[string] result;
        size_t at = 0;
        while (at < body_.length)
        {
            size_t cursor = at;
            while (cursor < body_.length && body_[cursor] != ' ')
                cursor++;
            if (cursor >= body_.length)
                break;
            size_t length = 0;
            foreach (b; body_[at .. cursor])
            {
                if (b < '0' || b > '9')
                    return result;
                length = length * 10 + (b - '0');
            }
            if (length == 0 || at + length > body_.length)
                break;
            auto record = body_[cursor + 1 .. at + length];
            size_t equals = 0;
            while (equals < record.length && record[equals] != '=')
                equals++;
            if (equals < record.length)
            {
                auto value = record[equals + 1 .. $];
                if (value.length > 0 && value[$ - 1] == '\n')
                    value = value[0 .. $ - 1];
                result[cast(string) record[0 .. equals].idup] = cast(string) value.idup;
            }
            at += length;
        }
        return result;
    }

    ArchiveEntry[] result;
    string pendingName, pendingLink;
    string[string] pendingPax;

    size_t offset = 0;
    while (offset + blockSize <= data.length)
    {
        auto header = data[offset .. offset + blockSize];
        offset += blockSize;

        bool empty = true;
        foreach (b; header)
            if (b != 0)
            {
                empty = false;
                break;
            }
        if (empty)
            continue;

        const size = parseNumber(header[124 .. 136]);
        const typeFlag = cast(char) header[156];
        const payloadEnd = offset + cast(size_t)((size + blockSize - 1) / blockSize * blockSize);
        auto payload = offset + size <= data.length ? data[offset .. offset + cast(size_t) size]
            : null;

        switch (typeFlag)
        {
        case 'L': // GNU long name for the entry that follows
            pendingName = trimmed(payload);
            offset = payloadEnd;
            continue;
        case 'K': // GNU long link target
            pendingLink = trimmed(payload);
            offset = payloadEnd;
            continue;
        case 'x': // PAX header for the entry that follows
        case 'g': // global PAX header
            foreach (key, value; parsePax(payload))
                pendingPax[key] = value;
            offset = payloadEnd;
            continue;
        default:
            break;
        }

        auto name = trimmed(header[0 .. 100]);
        // ustar splits long names across prefix and name.
        const prefix = trimmed(header[345 .. 500]);
        if (prefix.length > 0)
            name = prefix ~ "/" ~ name;
        if (pendingName.length > 0)
            name = pendingName;
        if (auto override_ = "path" in pendingPax)
            name = *override_;

        auto link = trimmed(header[157 .. 257]);
        if (pendingLink.length > 0)
            link = pendingLink;
        if (auto override_ = "linkpath" in pendingPax)
            link = *override_;

        switch (typeFlag)
        {
        case '0':
        case '\0':
        case '7': // contiguous file, read like a regular one
            if (payload !is null)
                result ~= ArchiveEntry(name, payload.dup, null, false);
            break;
        case '1':
        case '2':
            result ~= ArchiveEntry(name, null, link, true);
            break;
        default: // directories and device nodes carry nothing to install
            break;
        }

        pendingName = null;
        pendingLink = null;
        pendingPax = null;
        offset = payloadEnd;
    }
    return result;
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

unittest
{
    import std.conv : octal;
    import std.format : format;

    // Builds a tar by hand so the PAX and GNU long-name paths can be exercised
    // without depending on what a particular tar implementation emits.
    static ubyte[] header(string name, ulong size, char typeFlag, string link = "")
    {
        auto block = new ubyte[512];
        block[0 .. name.length] = cast(const(ubyte)[]) name;
        block[100 .. 108] = cast(const(ubyte)[]) "0000644\0";
        block[124 .. 136] = cast(const(ubyte)[]) format("%011o\0", size);
        block[136 .. 148] = cast(const(ubyte)[]) "00000000000\0";
        block[156] = cast(ubyte) typeFlag;
        if (link.length > 0)
            block[157 .. 157 + link.length] = cast(const(ubyte)[]) link;
        block[257 .. 263] = cast(const(ubyte)[]) "ustar\0";
        block[263 .. 265] = cast(const(ubyte)[]) "00";
        // The checksum is computed with the field itself read as spaces.
        block[148 .. 156] = cast(const(ubyte)[]) "        ";
        uint sum = 0;
        foreach (b; block)
            sum += b;
        block[148 .. 156] = cast(const(ubyte)[]) format("%06o\0 ", sum);
        return block;
    }

    static ubyte[] padded(const(ubyte)[] body_)
    {
        auto block = new ubyte[(body_.length + 511) / 512 * 512];
        block[0 .. body_.length] = body_;
        return block;
    }

    auto payload = cast(ubyte[]) "hello".dup;

    // A PAX record is "<len> <key>=<value>\n" where len counts itself, so
    // build it rather than hand-writing a number that can drift.
    static string paxRecord(string key, string value)
    {
        import std.conv : to;

        const body_ = " " ~ key ~ "=" ~ value ~ "\n";
        size_t length = body_.length + 1;
        while (length.to!string.length + body_.length != length)
            length++;
        return length.to!string ~ body_;
    }

    // A PAX header carrying the real path, exactly the shape squiz-box refused.
    const record = paxRecord("path", "deep/nested/binary");
    auto tarball = header("././@PaxHeader", record.length, 'x') ~ padded(cast(
            const(ubyte)[]) record) ~ header("short", payload.length,
            '0') ~ padded(payload) ~ new ubyte[1024];

    auto entries = readTar(tarball);
    assert(entries.length == 1);
    assert(entries[0].path == "deep/nested/binary", entries[0].path);
    assert(entries[0].data == payload);

    // A GNU long name applies to the entry that follows it.
    const longName = "a/very/long/path/that/exceeds/the/ustar/limit/binary";
    auto gnu = header("././@LongLink", longName.length, 'L') ~ padded(cast(const(
            ubyte)[]) longName) ~ header("truncated", payload.length,
            '0') ~ padded(payload) ~ new ubyte[1024];
    auto gnuEntries = readTar(gnu);
    assert(gnuEntries.length == 1);
    assert(gnuEntries[0].path == longName);

    // Symlinks are reported rather than treated as files.
    auto linked = header("lib.so", 0, '2', "lib.so.1") ~ new ubyte[1024];
    auto linkEntries = readTar(linked);
    assert(linkEntries.length == 1 && linkEntries[0].isSymlink);
    assert(linkEntries[0].linkTarget == "lib.so.1");
}

version (unittest) private uint octalAttributes()
{
    import std.conv : octal;

    return octal!"100644";
}
