{
  lib,
  buildDubPackage,
  ldc,
  patchelf,
  pkg-config,
  openssl,
  xz,
  bzip2,
  zstd,
  zlib,
}:

buildDubPackage rec {
  pname = "geto";
  version = "0.4.0";

  src = lib.cleanSource ../.;

  dubLock = ../dub-lock.json;

  nativeBuildInputs = [
    ldc
    patchelf
    pkg-config
  ];

  # squiz-box links bzip2, lzma and zstd; requests loads OpenSSL at run time.
  buildInputs = [
    openssl
    xz
    bzip2
    zstd
    zlib
  ];

  dubBuildType = "release";

  installPhase = ''
    runHook preInstall
    install -Dm755 geto $out/bin/geto
    runHook postInstall
  '';

  # `requests` loads OpenSSL with dlopen, so the linker never records it and it
  # has to be added to the RPATH by hand or every HTTPS request fails.
  postFixup = ''
    patchelf --add-rpath ${lib.makeLibraryPath [ openssl ]} $out/bin/geto
  '';

  meta = {
    description = "Effortless binary manager";
    homepage = "https://github.com/termworks/geto";
    license = lib.licenses.mit;
    mainProgram = "geto";
    platforms = lib.platforms.linux;
  };
}
