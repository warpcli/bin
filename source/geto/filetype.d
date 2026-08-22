module geto.filetype;

import std.string : toLower;

/// The file kinds geto reasons about. `otherKnown` covers formats that are
/// recognisable but never installable (images, media, other archive formats).
enum FileKind
{
    unknown,
    gz,
    tar,
    xz,
    bz2,
    zst,
    zip,
    exe,
    elf,
    deb,
    rpm,
    msi,
    asc,
    otherKnown,
}

/// Extensions that map to a kind geto handles specially.
private immutable FileKind[string] specificExtensions;

/// Extensions recognised by the detector but not installable.
private immutable bool[string] otherExtensions;

shared static this()
{
    FileKind[string] specific = [
        "gz": FileKind.gz,
        "tar": FileKind.tar,
        "xz": FileKind.xz,
        "bz2": FileKind.bz2,
        "zst": FileKind.zst,
        "zip": FileKind.zip,
        "exe": FileKind.exe,
        "elf": FileKind.elf,
        "deb": FileKind.deb,
        "rpm": FileKind.rpm,
        "msi": FileKind.msi,
        "asc": FileKind.asc,
    ];
    specificExtensions = cast(immutable) specific;

    bool[string] others;
    foreach (name; [
            "3gp", "7z", "aac", "aiff", "amr", "ar", "avi", "bmp", "cab", "cr2",
            "crx", "dcm", "dex", "dey", "doc", "docx", "dwg", "eot", "epub",
            "flac", "flv", "gif", "heif", "ico", "iso", "jp2", "jpg", "jxr",
            "lz", "m4a", "m4v", "macho", "mid", "mkv", "mov", "mp3", "mp4",
            "mpg", "nes", "ogg", "otf", "pdf", "png", "ppt", "pptx", "ps",
            "psd", "rar", "rtf", "sqlite", "swf", "tif", "ttf", "wasm", "wav",
            "webm", "webp", "wmv", "woff", "woff2", "xls", "xlsx", "z"
        ])
        others[name] = true;
    otherExtensions = cast(immutable) others;
}

/// Resolves an extension (without its dot) to a kind.
FileKind kindForExtension(string ext)
{
    const key = ext.toLower;
    if (auto found = key in specificExtensions)
        return *found;
    if (key in otherExtensions)
        return FileKind.otherKnown;
    return FileKind.unknown;
}

/// Identifies a buffer by its magic bytes. Only the formats geto can unpack
/// are distinguished; everything else reports `unknown`.
FileKind detect(const(ubyte)[] data)
{
    static bool startsWith(const(ubyte)[] data, const(ubyte)[] magic)
    {
        return data.length >= magic.length && data[0 .. magic.length] == magic;
    }

    if (startsWith(data, [0x1F, 0x8B]))
        return FileKind.gz;
    if (startsWith(data, [0xFD, '7', 'z', 'X', 'Z', 0x00]))
        return FileKind.xz;
    if (startsWith(data, [0x42, 0x5A, 0x68]))
        return FileKind.bz2;
    if (startsWith(data, [0x28, 0xB5, 0x2F, 0xFD]))
        return FileKind.zst;
    if (data.length > 3 && data[0] == 'P' && data[1] == 'K'
        && (data[2] == 3 || data[2] == 5 || data[2] == 7)
        && (data[3] == 4 || data[3] == 6 || data[3] == 8))
        return FileKind.zip;
    if (data.length > 261 && data[257 .. 262] == cast(const(ubyte)[]) "ustar")
        return FileKind.tar;
    if (startsWith(data, [0x7F, 'E', 'L', 'F']))
        return FileKind.elf;
    if (startsWith(data, [0x4D, 0x5A]))
        return FileKind.exe;
    return FileKind.unknown;
}

/// True for the archive and compression wrappers geto can unpack.
bool isCompressedKind(FileKind kind)
{
    switch (kind)
    {
    case FileKind.gz:
    case FileKind.tar:
    case FileKind.xz:
    case FileKind.bz2:
    case FileKind.zip:
        return true;
    default:
        return false;
    }
}

unittest
{
    assert(detect([0x1F, 0x8B, 0x08, 0x00]) == FileKind.gz);
    assert(detect([0x50, 0x4B, 0x03, 0x04]) == FileKind.zip);
    assert(detect([0x7F, 'E', 'L', 'F']) == FileKind.elf);
    assert(detect([0x00, 0x01]) == FileKind.unknown);

    assert(kindForExtension("GZ") == FileKind.gz);
    assert(kindForExtension("png") == FileKind.otherKnown);
    assert(kindForExtension("bin") == FileKind.unknown);

    ubyte[300] tar;
    tar[257 .. 262] = cast(const(ubyte)[]) "ustar";
    assert(detect(tar[]) == FileKind.tar);
}
