module geto.elf;

import std.file : exists, getAttributes, read, setAttributes, write;
import std.stdio : File;
import std.string : fromStringz;

/// Raised when an ELF operation cannot be completed.
class ElfException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/// Raised when a value no longer fits its existing slot and the image must grow.
final class NeedsGrowException : ElfException
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

private enum : uint
{
    ptLoad = 1,
    ptDynamic = 2,
    ptInterp = 3,
    ptNote = 4,
}

private enum uint pfRead = 4;

private enum : ulong
{
    dtNull = 0,
    dtNeeded = 1,
    dtStrtab = 5,
    dtStrsz = 10,
    dtRpath = 15,
    dtRunpath = 29,
}

// Field offsets within a 64-bit program header entry.
private enum
{
    pType = 0,
    pFlags = 4,
    pOffset = 8,
    pVaddr = 16,
    pPaddr = 24,
    pFilesz = 32,
    pMemsz = 40,
    pAlign = 48,
}

// Field offsets within a 64-bit section header entry.
private enum
{
    shAddr = 16,
    shOffset = 24,
    shSize = 32,
}

private enum size_t dynEntSize = 16;

// ---------------------------------------------------------------------------
// Little-endian primitives
// ---------------------------------------------------------------------------

private ushort readU16(const(ubyte)[] data, size_t offset)
{
    return cast(ushort)(data[offset] | (data[offset + 1] << 8));
}

private uint readU32(const(ubyte)[] data, size_t offset)
{
    return cast(uint)(data[offset] | (data[offset + 1] << 8) | (
            data[offset + 2] << 16) | (cast(uint) data[offset + 3] << 24));
}

private ulong readU64(const(ubyte)[] data, size_t offset)
{
    ulong value = 0;
    foreach_reverse (i; 0 .. 8)
        value = (value << 8) | data[offset + i];
    return value;
}

private void writeU32(ubyte[] data, size_t offset, uint value)
{
    foreach (i; 0 .. 4)
        data[offset + i] = cast(ubyte)(value >> (8 * i));
}

private void writeU64(ubyte[] data, size_t offset, ulong value)
{
    foreach (i; 0 .. 8)
        data[offset + i] = cast(ubyte)(value >> (8 * i));
}

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

/// Lenient ELF check accepting any class and endianness.
bool looksLikeElf(const(ubyte)[] data)
{
    if (data.length < 20 || data[0 .. 4] != cast(const(ubyte)[]) "\x7fELF")
        return false;
    if (data[4] != 1 && data[4] != 2)
        return false;
    if (data[5] != 1 && data[5] != 2)
        return false;
    return true;
}

/// Lenient PE check mirroring what `debug/pe` accepts.
bool looksLikePe(const(ubyte)[] data)
{
    if (data.length < 0x40 || data[0] != 'M' || data[1] != 'Z')
        return false;
    const headerOffset = readU32(data, 0x3C);
    if (headerOffset + 4 > data.length)
        return false;
    return data[headerOffset .. headerOffset + 4] == cast(const(ubyte)[]) "PE\0\0";
}

/// True when the buffer parses as an executable object file.
bool isBinaryImage(const(ubyte)[] data)
{
    return looksLikeElf(data) || looksLikePe(data);
}

// ---------------------------------------------------------------------------
// Image
// ---------------------------------------------------------------------------

/// A mutable in-memory 64-bit little-endian ELF image.
final class ElfImage
{
    ubyte[] data;
    uint attributes;
    ulong phoff;
    size_t phentsize;
    size_t phnum;
    ulong shoff;
    size_t shentsize;
    size_t shnum;

    private this()
    {
    }

    /// Parses a buffer, throwing when it is not a 64-bit little-endian ELF.
    static ElfImage fromBuffer(ubyte[] buffer)
    {
        if (buffer.length < 64 || buffer[0 .. 4] != cast(const(ubyte)[]) "\x7fELF")
            throw new ElfException("not an ELF file");
        if (buffer[4] != 2)
            throw new ElfException("only 64-bit ELF is supported");
        if (buffer[5] != 1)
            throw new ElfException("only little-endian ELF is supported");

        auto image = new ElfImage;
        image.data = buffer;
        image.phoff = readU64(buffer, 0x20);
        image.phentsize = readU16(buffer, 0x36);
        image.phnum = readU16(buffer, 0x38);
        image.shoff = readU64(buffer, 0x28);
        image.shentsize = readU16(buffer, 0x3A);
        image.shnum = readU16(buffer, 0x3C);
        if (image.phoff == 0 || image.phentsize < 56)
            throw new ElfException("missing or malformed program header table");
        return image;
    }

    private size_t progOff(size_t index) const
    {
        return cast(size_t) phoff + index * phentsize;
    }

    ulong progU64(size_t index, size_t field) const
    {
        return readU64(data, progOff(index) + field);
    }

    uint progU32(size_t index, size_t field) const
    {
        return readU32(data, progOff(index) + field);
    }

    void setProgU64(size_t index, size_t field, ulong value)
    {
        writeU64(data, progOff(index) + field, value);
    }

    void setProgU32(size_t index, size_t field, uint value)
    {
        writeU32(data, progOff(index) + field, value);
    }

    /// Index of the first program header of the given type, or -1.
    long findProg(uint type) const
    {
        foreach (i; 0 .. phnum)
            if (progU32(i, pType) == type)
                return cast(long) i;
        return -1;
    }

    /// Maps a virtual address to a file offset through the PT_LOAD segments.
    bool vaddrToOff(ulong vaddr, out ulong offset) const
    {
        foreach (i; 0 .. phnum)
        {
            if (progU32(i, pType) != ptLoad)
                continue;
            const base = progU64(i, pVaddr);
            const size = progU64(i, pFilesz);
            if (vaddr >= base && vaddr < base + size)
            {
                offset = progU64(i, pOffset) + (vaddr - base);
                return true;
            }
        }
        return false;
    }

    /// The highest end address across all PT_LOAD segments.
    ulong maxLoadVaddrEnd() const
    {
        ulong end = 0;
        foreach (i; 0 .. phnum)
        {
            if (progU32(i, pType) != ptLoad)
                continue;
            const candidate = progU64(i, pVaddr) + progU64(i, pMemsz);
            if (candidate > end)
                end = candidate;
        }
        return end;
    }

    /// Rewrites the section header whose address matches `addr`.
    void setSectionByAddr(ulong addr, ulong newOff, ulong newSize, ulong newAddr)
    {
        if (shoff == 0)
            return;
        foreach (i; 0 .. shnum)
        {
            const base = cast(size_t) shoff + i * shentsize;
            if (base + shSize + 8 > data.length)
                return;
            if (readU64(data, base + shAddr) == addr)
            {
                writeU64(data, base + shOffset, newOff);
                writeU64(data, base + shSize, newSize);
                writeU64(data, base + shAddr, newAddr);
                return;
            }
        }
    }

    /// Offset and size of the dynamic string table, if resolvable.
    private bool dynstrRange(out ulong offset, out ulong size) const
    {
        ulong strtabVaddr, strsz;
        if (!dynamicValue(dtStrtab, strtabVaddr) || !dynamicValue(dtStrsz, strsz))
            return false;
        if (!vaddrToOff(strtabVaddr, offset))
            return false;
        if (offset + strsz > data.length)
            return false;
        size = strsz;
        return true;
    }

    /// The first value stored against a dynamic tag.
    private bool dynamicValue(ulong tag, out ulong value) const
    {
        const index = findProg(ptDynamic);
        if (index < 0)
            return false;
        const base = cast(size_t) progU64(index, pOffset);
        const count = cast(size_t) progU64(index, pFilesz) / dynEntSize;
        foreach (k; 0 .. count)
        {
            const entry = base + k * dynEntSize;
            if (entry + dynEntSize > data.length)
                return false;
            if (readU64(data, entry) == tag)
            {
                value = readU64(data, entry + 8);
                return true;
            }
        }
        return false;
    }

    /// All values stored against a dynamic tag, resolved through .dynstr.
    string[] dynamicStrings(ulong tag) const
    {
        ulong strOff, strSize;
        if (!dynstrRange(strOff, strSize))
            return null;
        const index = findProg(ptDynamic);
        if (index < 0)
            return null;
        const base = cast(size_t) progU64(index, pOffset);
        const count = cast(size_t) progU64(index, pFilesz) / dynEntSize;

        string[] result;
        foreach (k; 0 .. count)
        {
            const entry = base + k * dynEntSize;
            if (entry + dynEntSize > data.length)
                break;
            if (readU64(data, entry) != tag)
                continue;
            const nameOff = readU64(data, entry + 8);
            if (nameOff >= strSize)
                continue;
            result ~= readCString(data, cast(size_t)(strOff + nameOff));
        }
        return result;
    }

    void save(string path)
    {
        write(path, data);
        setAttributes(path, attributes);
    }
}

private string readCString(const(ubyte)[] data, size_t offset)
{
    size_t end = offset;
    while (end < data.length && data[end] != 0)
        end++;
    return cast(string) data[offset .. end].idup;
}

// ---------------------------------------------------------------------------
// Targeted reading
// ---------------------------------------------------------------------------

/// Reads only the regions of an ELF file it is asked about. Metadata queries
/// then cost a few kilobytes instead of the whole binary, which matters when
/// the TUI inspects every managed binary on each refresh.
final class ElfReader
{
    private File file;
    private ushort machineValue;
    private ulong phoff;
    private size_t phentsize;
    private size_t phnum;
    private ubyte[] programHeaders;

    private this()
    {
    }

    /// Opens `path`, or returns null when it is not a 64-bit little-endian ELF.
    static ElfReader open(string path)
    {
        auto reader = new ElfReader;
        try
        {
            reader.file = File(path, "rb");
            ubyte[64] header;
            auto got = reader.file.rawRead(header[]);
            if (got.length < 64 || got[0 .. 4] != cast(const(ubyte)[]) "\x7fELF"
                    || got[4] != 2 || got[5] != 1)
                return null;

            reader.machineValue = readU16(got[], 18);
            reader.phoff = readU64(got[], 0x20);
            reader.phentsize = readU16(got[], 0x36);
            reader.phnum = readU16(got[], 0x38);
            if (reader.phoff == 0 || reader.phentsize < 56 || reader.phnum == 0)
                return null;
            if (reader.phnum > 4096)
                return null;

            reader.programHeaders = reader.readAt(reader.phoff, reader.phentsize * reader.phnum);
            if (reader.programHeaders.length < reader.phentsize * reader.phnum)
                return null;
        }
        catch (Exception)
            return null;
        return reader;
    }

    private ubyte[] readAt(ulong offset, size_t length)
    {
        if (length == 0 || length > 64 * 1024 * 1024)
            return null;
        try
        {
            file.seek(cast(long) offset);
            auto buffer = new ubyte[length];
            return file.rawRead(buffer);
        }
        catch (Exception)
            return null;
    }

    private uint progU32(size_t index, size_t field) const
    {
        return readU32(programHeaders, index * phentsize + field);
    }

    private ulong progU64(size_t index, size_t field) const
    {
        return readU64(programHeaders, index * phentsize + field);
    }

    private long findProg(uint type) const
    {
        foreach (i; 0 .. phnum)
            if (progU32(i, pType) == type)
                return cast(long) i;
        return -1;
    }

    private bool vaddrToOff(ulong vaddr, out ulong offset) const
    {
        foreach (i; 0 .. phnum)
        {
            if (progU32(i, pType) != ptLoad)
                continue;
            const base = progU64(i, pVaddr);
            const size = progU64(i, pFilesz);
            if (vaddr >= base && vaddr < base + size)
            {
                offset = progU64(i, pOffset) + (vaddr - base);
                return true;
            }
        }
        return false;
    }

    /// The `e_machine` value.
    ushort machine() const
    {
        return machineValue;
    }

    /// The PT_INTERP path, or "" for a static binary.
    string interpreter()
    {
        const index = findProg(ptInterp);
        if (index < 0)
            return "";
        const size = cast(size_t) progU64(index, pFilesz);
        if (size == 0 || size > 4096)
            return "";
        auto data = readAt(progU64(index, pOffset), size);
        return data.length == 0 ? "" : readCString(data, 0);
    }

    /// The dynamic-section entries, paired with the string table they index.
    private bool dynamic(out ubyte[] entries, out ubyte[] strings, out ulong stringsSize)
    {
        const index = findProg(ptDynamic);
        if (index < 0)
            return false;
        entries = readAt(progU64(index, pOffset), cast(size_t) progU64(index, pFilesz));
        if (entries.length < dynEntSize)
            return false;

        ulong strtabVaddr, strsz;
        bool haveStrtab, haveStrsz;
        for (size_t k = 0; (k + 1) * dynEntSize <= entries.length; k++)
        {
            const tag = readU64(entries, k * dynEntSize);
            const value = readU64(entries, k * dynEntSize + 8);
            if (tag == dtStrtab)
            {
                strtabVaddr = value;
                haveStrtab = true;
            }
            else if (tag == dtStrsz)
            {
                strsz = value;
                haveStrsz = true;
            }
        }
        if (!haveStrtab || !haveStrsz || strsz == 0)
            return false;

        ulong strOff;
        if (!vaddrToOff(strtabVaddr, strOff))
            return false;
        strings = readAt(strOff, cast(size_t) strsz);
        stringsSize = strings.length;
        return strings.length > 0;
    }

    private string[] dynamicStrings(ulong tag)
    {
        ubyte[] entries, strings;
        ulong stringsSize;
        if (!dynamic(entries, strings, stringsSize))
            return null;

        string[] result;
        for (size_t k = 0; (k + 1) * dynEntSize <= entries.length; k++)
        {
            if (readU64(entries, k * dynEntSize) != tag)
                continue;
            const nameOff = readU64(entries, k * dynEntSize + 8);
            if (nameOff >= stringsSize)
                continue;
            result ~= readCString(strings, cast(size_t) nameOff);
        }
        return result;
    }

    /// Shared libraries declared through DT_NEEDED.
    string[] needed()
    {
        return dynamicStrings(dtNeeded);
    }

    /// DT_RUNPATH entries, falling back to DT_RPATH.
    string[] runpathEntries()
    {
        auto entries = dynamicStrings(dtRunpath);
        return entries.length > 0 ? entries : dynamicStrings(dtRpath);
    }
}

private ElfImage loadImage(string path)
{
    auto buffer = cast(ubyte[]) read(path);
    auto image = ElfImage.fromBuffer(buffer);
    image.attributes = getAttributes(path);
    return image;
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/// Shared libraries the buffer declares through DT_NEEDED.
string[] importedLibraries(const(ubyte)[] data)
{
    if (data.length < 64 || data[0 .. 4] != cast(const(ubyte)[]) "\x7fELF"
            || data[4] != 2 || data[5] != 1)
        return null;
    try
    {
        auto image = ElfImage.fromBuffer(cast(ubyte[]) data.dup);
        return image.dynamicStrings(dtNeeded);
    }
    catch (Exception)
        return null;
}

/// The binary's PT_INTERP path.
string interpreter(string path)
{
    auto reader = ElfReader.open(path);
    if (reader is null)
        throw new ElfException("not a 64-bit little-endian ELF file");
    const interp = reader.interpreter();
    if (interp.length == 0)
        throw new ElfException("no interpreter");
    return interp;
}

/// The binary's DT_RUNPATH entries, falling back to DT_RPATH.
string[] runpath(string path)
{
    auto reader = ElfReader.open(path);
    return reader is null ? null : reader.runpathEntries();
}

// ---------------------------------------------------------------------------
// Patching
// ---------------------------------------------------------------------------

/// Points the binary at a new ELF interpreter.
void setInterpreter(string path, string interp)
{
    auto image = loadImage(path);
    const index = image.findProg(ptInterp);
    if (index < 0)
        throw new ElfException("no PT_INTERP segment (statically linked?)");

    auto value = cast(ubyte[])(interp.dup) ~ cast(ubyte) 0;
    const offset = cast(size_t) image.progU64(index, pOffset);
    const size = cast(size_t) image.progU64(index, pFilesz);

    if (value.length <= size)
    {
        image.data[offset .. offset + size] = 0;
        image.data[offset .. offset + value.length] = value;
    }
    else
    {
        // No room in the existing slot; append the path at end of file.
        const newOffset = image.data.length;
        image.data ~= value;
        image.setProgU64(index, pOffset, newOffset);
        image.setProgU64(index, pFilesz, value.length);
        image.setProgU64(index, pMemsz, value.length);
    }
    image.save(path);
}

/// Sets DT_RUNPATH, growing the image only when the value will not fit.
void setRunpath(string path, string rpath)
{
    try
    {
        setRunpathInPlace(path, rpath);
        return;
    }
    catch (NeedsGrowException)
    {
    }
    setRunpathGrow(path, rpath);
}

private void setRunpathInPlace(string path, string rpath)
{
    auto image = loadImage(path);
    auto current = image.dynamicStrings(dtRunpath);
    if (current.length == 0)
        current = image.dynamicStrings(dtRpath);

    ulong strOff, strSize;
    if (current.length == 0 || !image.dynstrRange(strOff, strSize))
        throw new NeedsGrowException("no existing RUNPATH/RPATH to edit");

    const old = current[0];
    if (rpath.length > old.length)
        throw new NeedsGrowException("rpath longer than slot");

    auto needle = cast(ubyte[])(old.dup) ~ cast(ubyte) 0;
    auto haystack = image.data[cast(size_t) strOff .. cast(size_t)(strOff + strSize)];
    const found = indexOfBytes(haystack, needle);
    if (found < 0)
        throw new ElfException("could not locate current rpath in .dynstr");

    const target = cast(size_t) strOff + cast(size_t) found;
    image.data[target .. target + old.length + 1] = 0;
    image.data[target .. target + rpath.length] = cast(const(ubyte)[]) rpath;
    image.save(path);
}

private long indexOfBytes(const(ubyte)[] haystack, const(ubyte)[] needle)
{
    if (needle.length == 0 || haystack.length < needle.length)
        return -1;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle)
            return cast(long) i;
    return -1;
}

/// Appends a rebuilt .dynstr and repoints the dynamic entries at it.
private void setRunpathGrow(string path, string rpath)
{
    auto image = loadImage(path);

    const dynIndex = image.findProg(ptDynamic);
    if (dynIndex < 0)
        throw new ElfException("no PT_DYNAMIC segment");
    const dynOff = cast(size_t) image.progU64(dynIndex, pOffset);
    const count = cast(size_t) image.progU64(dynIndex, pFilesz) / dynEntSize;

    long idxStrtab = -1, idxStrsz = -1, idxRunpath = -1, idxRpath = -1, idxNull = -1;
    ulong strtabVaddr, strsz;
    foreach (k; 0 .. count)
    {
        const entry = dynOff + k * dynEntSize;
        const tag = readU64(image.data, entry);
        const value = readU64(image.data, entry + 8);
        switch (tag)
        {
        case dtNull:
            if (idxNull < 0)
                idxNull = cast(long) k;
            break;
        case dtStrtab:
            idxStrtab = cast(long) k;
            strtabVaddr = value;
            break;
        case dtStrsz:
            idxStrsz = cast(long) k;
            strsz = value;
            break;
        case dtRunpath:
            idxRunpath = cast(long) k;
            break;
        case dtRpath:
            idxRpath = cast(long) k;
            break;
        default:
            break;
        }
    }
    if (idxStrtab < 0 || idxStrsz < 0)
        throw new ElfException("missing DT_STRTAB/DT_STRSZ");

    ulong strFileOff;
    if (!image.vaddrToOff(strtabVaddr, strFileOff) || strFileOff + strsz > image.data.length)
        throw new ElfException("cannot locate existing .dynstr");

    auto rebuilt = image.data[cast(size_t) strFileOff .. cast(size_t)(strFileOff + strsz)].dup;
    const rpathOff = rebuilt.length;
    rebuilt ~= cast(const(ubyte)[]) rpath;
    rebuilt ~= cast(ubyte) 0;

    const noteIndex = image.findProg(ptNote);
    if (noteIndex < 0)
        throw new NeedsGrowException("no PT_NOTE segment to repurpose");

    enum ulong align_ = 0x1000;
    const fileOff = cast(ulong) image.data.length;
    const base = (image.maxLoadVaddrEnd() + align_ - 1) / align_ * align_;
    const vaddr = base + (fileOff % align_);

    image.data ~= rebuilt;

    // Repurpose PT_NOTE as a read-only PT_LOAD covering the new string table.
    image.setProgU32(noteIndex, pType, ptLoad);
    image.setProgU32(noteIndex, pFlags, pfRead);
    image.setProgU64(noteIndex, pOffset, fileOff);
    image.setProgU64(noteIndex, pVaddr, vaddr);
    image.setProgU64(noteIndex, pPaddr, vaddr);
    image.setProgU64(noteIndex, pFilesz, rebuilt.length);
    image.setProgU64(noteIndex, pMemsz, rebuilt.length);
    image.setProgU64(noteIndex, pAlign, align_);

    void setVal(long k, ulong value)
    {
        writeU64(image.data, dynOff + cast(size_t) k * dynEntSize + 8, value);
    }

    void setTag(long k, ulong tag)
    {
        writeU64(image.data, dynOff + cast(size_t) k * dynEntSize, tag);
    }

    setVal(idxStrtab, vaddr);
    setVal(idxStrsz, rebuilt.length);
    if (idxRunpath >= 0)
        setVal(idxRunpath, rpathOff);
    else if (idxRpath >= 0)
    {
        setTag(idxRpath, dtRunpath);
        setVal(idxRpath, rpathOff);
    }
    else if (idxNull >= 0 && idxNull < cast(long) count - 1)
    {
        setTag(idxNull, dtRunpath);
        setVal(idxNull, rpathOff);
    }
    else
        throw new NeedsGrowException("no spare dynamic slot for DT_RUNPATH");

    image.setSectionByAddr(strtabVaddr, fileOff, rebuilt.length, vaddr);
    image.save(path);
}

unittest
{
    assert(!looksLikeElf([0x00, 0x01, 0x02, 0x03]));
    assert(looksLikeElf(cast(const(
            ubyte)[]) "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"));

    ubyte[0x80] pe;
    pe[0] = 'M';
    pe[1] = 'Z';
    writeU32(pe[], 0x3C, 0x40);
    pe[0x40 .. 0x44] = cast(const(ubyte)[]) "PE\0\0";
    assert(looksLikePe(pe[]));
}

unittest
{
    import std.algorithm : canFind;
    import std.file : thisExePath;

    // The test runner is itself a 64-bit ELF, so it makes a convenient fixture
    // and proves the targeted reader agrees with a full parse.
    auto reader = ElfReader.open(thisExePath);
    assert(reader !is null);
    assert(reader.machine() != 0);

    auto whole = cast(ubyte[]) read(thisExePath);
    assert(looksLikeElf(whole));
    assert(reader.needed() == importedLibraries(whole));

    const interp = reader.interpreter();
    if (interp.length > 0)
        assert(interp[0] == '/', interp);

    // A non-ELF file is rejected rather than throwing.
    assert(ElfReader.open("/etc/hostname") is null || !"/etc/hostname".exists);
}
