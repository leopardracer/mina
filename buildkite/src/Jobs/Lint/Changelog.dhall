let S = ../../Lib/SelectFiles.dhall

let Cmd = ../../Lib/Cmds.dhall

let Pipeline = ../../Pipeline/Dsl.dhall

let JobSpec = ../../Pipeline/JobSpec.dhall

let Command = ../../Command/Base.dhall

let Size = ../../Command/Size.dhall

let trigger = S.compile [ S.strictlyStart (S.contains "src") ]

let reqFile = "^changes/\\\${BUILDKITE_PULL_REQUEST}-.*.md"

in  Pipeline.build
      Pipeline.Config::{
      , spec = JobSpec::{
        , dirtyWhen =
          [ S.contains "src"
          , S.exactly "buildkite/src/Jobs/Lint/Changelog" "dhall"
          ]
        , path = "Lint"
        , name = "Changelog"
        }
      , steps =
        [ Command.build
            Command.Config::{
            , commands =
              [ Cmd.run "./buildkite/scripts/changelog.sh ${trigger} ${reqFile}"
              ]
            , label = "Lint: Changelog"
            , key = "lint-changelog"
            , target = Size.Multi
            }
        ]
      }
