-- TODO: Automatically push, tag, and update images #4862
-- NOTE: minaToolchainStretch is also used for building Ubuntu Bionic packages in CI
-- NOTE: minaToolchainBullseye is also used for building Ubuntu Focal packages in CI
{
  toolchainBase = "codaprotocol/ci-toolchain-base:v3",
  minaToolchainBullseye = "gcr.io/o1labs-192920/mina-toolchain@sha256:0c5194cf888339bc9471d38068989f9fe3c3f553f60b5e663e025e902101686f",
  minaToolchainBuster = "gcr.io/o1labs-192920/mina-toolchain@sha256:c050a8f471a500a6b3532875f2efbf3f6b5f915eb6bf814519c757966eee9759",
  minaToolchainStretch = "gcr.io/o1labs-192920/mina-toolchain@sha256:84d29bacb717702bc667987e6896c4dd3cb7b79e196a0ceaab6ff3e03020390a",
  delegationBackendToolchain = "gcr.io/o1labs-192920/delegation-backend-production@sha256:8ca5880845514ef56a36bf766a0f9de96e6200d61b51f80d9f684a0ec9c031f4",
  elixirToolchain = "elixir:1.10-alpine",
  rustToolchain = "codaprotocol/coda:toolchain-rust-e855336d087a679f76f2dd2bbdc3fdfea9303be3",
  nodeToolchain = "node:14.13.1-stretch-slim",
  ubuntu1804 = "ubuntu:18.04",
  xrefcheck = "serokell/xrefcheck@sha256:8fbb35a909abc353364f1bd3148614a1160ef3c111c0c4ae84e58fdf16019eeb"
}
