let Prelude = ../../External/Prelude.dhall
let B = ../../External/Buildkite.dhall

let Cmd = ../../Lib/Cmds.dhall
let S = ../../Lib/SelectFiles.dhall

let Pipeline = ../../Pipeline/Dsl.dhall
let PipelineMode = ../../Pipeline/Mode.dhall
let JobSpec = ../../Pipeline/JobSpec.dhall

let Command = ../../Command/Base.dhall
let RunInToolchain = ../../Command/RunInToolchain.dhall
let Size = ../../Command/Size.dhall
let Libp2p = ../../Command/Libp2pHelperBuild.dhall
let DockerImage = ../../Command/DockerImage.dhall
let DebianVersions = ../../Constants/DebianVersions.dhall

let dirtyWhen = [ 
  S.strictlyStart (S.contains "src/app/rosetta"),
  S.strictlyStart (S.contains "src/lib"),
  S.strictlyStart (S.contains "src/app/archive"),
  S.exactly "buildkite/src/Jobs/Test/RosettaIntegrationTests" "dhall",
  S.exactly "buildkite/scripts/rosetta-integration-tests" "sh",
  S.exactly "buildkite/scripts/rosetta-integration-tests-full" "sh"
]

let B/SoftFail = B.definitions/commandStep/properties/soft_fail/Type

in

Pipeline.build
  Pipeline.Config::
    { spec =
      JobSpec::{
        dirtyWhen = dirtyWhen,
        path = "Test",
        name = "RosettaIntegrationTestsLong",
        mode = PipelineMode.Type.Stable
      }
    , steps = [
      Command.build
        Command.Config::{
          commands = [
            Cmd.run ("export MINA_DEB_CODENAME=bullseye && source ./buildkite/scripts/export-git-env-vars.sh && echo \\\${MINA_DOCKER_TAG}"),
            Cmd.runInDocker Cmd.Docker::{image="gcr.io/o1labs-192920/mina-rosetta:\\\${MINA_DOCKER_TAG}"} "buildkite/scripts/rosetta-integration-tests-full.sh"
          ],
          label = "Rosetta integration tests Bullseye Long"
          , key = "rosetta-integration-tests-bullseye-long"
          , target = Size.Small
          , depends_on = [ { name = "MinaArtifactBullseye", key = "rosetta-bullseye-docker-image" } ]
        }
    ]
  }