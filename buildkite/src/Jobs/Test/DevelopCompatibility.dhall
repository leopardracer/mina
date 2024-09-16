let JobSpec = ../../Pipeline/JobSpec.dhall

let Pipeline = ../../Pipeline/Dsl.dhall

let PipelineTag = ../../Pipeline/Tag.dhall

let Cmd = ../../Lib/Cmds.dhall

let S = ../../Lib/SelectFiles.dhall

let Command = ../../Command/Base.dhall

let Docker = ../../Command/Docker/Type.dhall

let DebianVersions = ../../Constants/DebianVersions.dhall

let Network = ../../Constants/Network.dhall

let Profiles = ../../Constants/Profiles.dhall

let dependsOn =
      DebianVersions.dependsOn
        DebianVersions.DebVersion.Bullseye
        Network.Type.Devnet
        Profiles.Type.Lightnet

in  Pipeline.build
      Pipeline.Config::{
      , spec = JobSpec::{
        , dirtyWhen =
          [ S.strictlyStart (S.contains "src")
          , S.exactly "buildkite/scripts/check-compatibility" "sh"
          , S.exactly "buildkite/src/Jobs/Test/DevelopCompatibility" "dhall"
          ]
        , path = "Test"
        , tags = [ PipelineTag.Type.Long, PipelineTag.Type.Test ]
        , name = "DevelopCompatibility"
        }
      , steps =
        [ Command.build
            Command.Config::{
            , commands =
              [ Cmd.run "buildkite/scripts/check-compatibility.sh develop" ]
            , label = "Test: develop compatibilty test"
            , key = "develop-compatibilty-test"
            , docker = None Docker.Type
            , depends_on = dependsOn
            , timeout_in_minutes = Some +60
            }
        ]
      }
