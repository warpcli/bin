{
  lib,
  buildGoModule,
}:

buildGoModule rec {
  pname = "bin";
  version = "0.3.0";

  src = lib.cleanSource ../.;
  subPackages = [ "src" ];

  vendorHash = "sha256-7gFr7Z9v7eefoLe6M8GKGj2x/ALi/Dkx5Z/KaS5TGPA=";

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
    "-X main.builtBy=nix"
  ];

  meta = {
    description = "Effortless binary manager";
    homepage = "https://github.com/bresilla/bin";
    license = lib.licenses.mit;
    mainProgram = "bin";
  };
}
