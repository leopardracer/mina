let S = ../../Lib/SelectFiles.dhall

let Pipeline = ../../Pipeline/Dsl.dhall

let PipelineTag = ../../Pipeline/Tag.dhall

let JobSpec = ../../Pipeline/JobSpec.dhall

let Command = ../../Command/Base.dhall

let RunInToolchain = ../../Command/RunInToolchain.dhall

let Docker = ../../Command/Docker/Type.dhall

let Size = ../../Command/Size.dhall

let buildTestCmd
    : Text -> Text -> Size -> Command.Type
    =     \(profile : Text)
      ->  \(path : Text)
      ->  \(cmd_target : Size)
      ->  let key = "rosetta-unit-test-${profile}"

          in  Command.build
                Command.Config::{
                , commands =
                    RunInToolchain.runInToolchain
                      [ "DUNE_INSTRUMENT_WITH=bisect_ppx", "COVERALLS_TOKEN" ]
                      "buildkite/scripts/unit-test.sh ${profile} ${path} && buildkite/scripts/upload-partial-coverage-data.sh ${key} dev"
                , label = "Test: Rosetta unit tests"
                , key = key
                , target = cmd_target
                , docker = None Docker.Type
                , artifact_paths = [ S.contains "core_dumps/*" ]
                }

in  Pipeline.build
      Pipeline.Config::{
      , spec =
          let unitDirtyWhen =
                [ S.strictlyStart (S.contains "src")
                , S.exactly "buildkite/src/Jobs/Test/RosettaUnitTest" "dhall"
                , S.exactly "buildkite/scripts/unit-test" "sh"
                ]

          in  JobSpec::{
              , dirtyWhen = unitDirtyWhen
              , path = "Test"
              , name = "RosettaUnitTest"
              , tags =
                [ PipelineTag.Type.Long
                , PipelineTag.Type.Test
                , PipelineTag.Type.Stable
                ]
              }
      , steps = [ buildTestCmd "dev" "src/app/rosetta" Size.Small ]
      }
