module Spago.Command.Build
  ( run
  , BuildEnv
  ) where

import Spago.Prelude

import Ansi.Codes (GraphicsParam)
import Data.Array as Array
import Data.Codec.Argonaut as CA
import Data.Map as Map
import Data.Set as Set
import Data.String as String
import Data.Tuple as Tuple
import Dodo (Doc)
import Registry.PackageName as PackageName
import Spago.BuildInfo as BuildInfo
import Spago.Cmd as Cmd
import Spago.Config (Package(..), Workspace, WorkspacePackage)
import Spago.Config as Config
import Spago.Git (Git)
import Spago.Log as Log
import Spago.Purs (Purs)
import Spago.Purs as Purs
import Spago.Purs.Graph as Graph

type BuildEnv a =
  { purs :: Purs
  , git :: Git
  , dependencies :: Map PackageName Package
  , logOptions :: LogOptions
  , workspace :: Workspace
  | a
  }

type BuildOptions =
  { depsOnly :: Boolean
  , pursArgs :: Array String
  }

run :: forall a. BuildOptions -> Spago (BuildEnv a) Unit
run opts = do
  logInfo "Building..."
  { dependencies, workspace } <- ask
  let dependencyGlobs = map (Tuple.uncurry Config.sourceGlob) (Map.toUnfoldable dependencies)

  -- Here we select the right globs for a monorepo setup
  let
    -- TODO: here depsOnly means "no packages from the monorepo", but right now we include local dependencies from the monorepo
    projectSources =
      if opts.depsOnly then []
      else case workspace.selected of
        Just p -> [ workspacePackageGlob p ]
        -- We just select all the workspace package globs, because it's (1) intuitive and (2) backwards compatible
        Nothing -> map workspacePackageGlob (Config.getWorkspacePackages workspace.packageSet)
  logDebug $ "Project sources: " <> show projectSources

  BuildInfo.writeBuildInfo

  -- find the output flag and die if it's there - Spago handles it
  when (isJust $ Cmd.findFlag { flags: [ "-o", "--output" ], args: opts.pursArgs }) do
    die
      [ "Can't pass `--output` option directly to purs."
      , "Use the --output flag for Spago, or add it to your config file."
      ]
  let
    addOutputArgs args = case workspace.buildOptions.output of
      Nothing -> args
      Just output -> args <> [ "--output", output ]

  let
    buildBackend globs = do
      case workspace.backend of
        Nothing ->
          Purs.compile globs (addOutputArgs opts.pursArgs)
        Just backend -> do
          when (isJust $ Cmd.findFlag { flags: [ "-g", "--codegen" ], args: opts.pursArgs }) do
            die
              [ "Can't pass `--codegen` option to build when using a backend"
              , "Hint: No need to pass `--codegen corefn` explicitly when using the `backend` option."
              , "Remove the argument to solve the error"
              ]
          Purs.compile globs $ (addOutputArgs opts.pursArgs) <> [ "--codegen", "corefn" ]

          logInfo $ "Compiling with backend \"" <> backend.cmd <> "\""
          logDebug $ "Running command `" <> backend.cmd <> "`"
          let
            moreBackendArgs = case backend.args of
              Just as | Array.length as > 0 -> as
              _ -> []
          Cmd.exec backend.cmd (addOutputArgs moreBackendArgs) Cmd.defaultExecOptions >>= case _ of
            Left err -> do
              logDebug $ show err
              die [ "Failed to build with backend " <> backend.cmd ]
            Right _r ->
              logSuccess "Backend build succeeded."

  {-
  TODO: before, then, else
      buildAction globs = do
        let action = buildBackend globs >> (fromMaybe (pure ()) maybePostBuild)
        runCommands "Before" beforeCommands
        action `onException` (runCommands "Else" elseCommands)
        runCommands "Then" thenCommands
  -}

  let globs = Set.fromFoldable $ join projectSources <> join dependencyGlobs <> [ BuildInfo.buildInfoPath ]
  buildBackend globs

  when workspace.buildOptions.pedanticPackages do
    logInfo $ "Looking for unused and undeclared transitive dependencies..."
    case workspace.selected of
      Just selected -> runGraphCheck selected globs >>= die
      Nothing -> do
        -- TODO: here we could go through all the workspace packages and run the check for each
        -- The complication is that "dependencies" includes all the dependencies for all packages
        errors <- for (Config.getWorkspacePackages workspace.packageSet) \selected -> do
          let pkgGlobs = Set.fromFoldable $ join projectSources <> join dependencyGlobs <> [ BuildInfo.buildInfoPath ]
          runGraphCheck selected pkgGlobs
        die errors

  where

  workspacePackageGlob :: WorkspacePackage -> Array String
  workspacePackageGlob p = Config.sourceGlob p.package.name (WorkspacePackage p)

  runGraphCheck :: _ -> _ -> Spago (BuildEnv a) (Array (Array (Doc GraphicsParam)))
  runGraphCheck selected globs = do
    { logOptions, dependencies } <- ask
    maybeGraph <- Purs.graph globs opts.pursArgs
    case maybeGraph of
      Left err -> do
        logWarn $ "Could not decode the output of `purs graph`, error: " <> CA.printJsonDecodeError err
        pure []
      Right graph -> do
        let graphEnv = { graph, selected, dependencies, logOptions }
        { unused, transitive } <- runSpago graphEnv Graph.checkImports

        let
          result =
            case Set.isEmpty unused of
              true -> []
              false -> [ unusedError selected unused ]
              <> case Map.isEmpty transitive of
                true -> []
                false -> [ transitiveError selected transitive ]

        pure result

  unusedError selected unused =
    [ Log.break
    , toDoc $ "Package '" <> PackageName.print selected.package.name <> "' declares unused dependencies - please remove them from the project config:"
    , indent (toDoc (map (\p -> PackageName.print p) (Set.toUnfoldable unused) :: Array _))
    ]
  transitiveError selected transitive =
    [ Log.break
    , toDoc $ "Package '" <> PackageName.print selected.package.name <> "' imports the following transitive dependencies - please add them to the project dependencies, or remove the imports:"
    , indent $ toDoc
        ( map
            ( \(Tuple p modules) -> toDoc
                [ toDoc $ PackageName.print p
                , indent $ toDoc
                    ( map
                        ( \(Tuple mod importedOnes) -> toDoc
                            [ toDoc $ "from `" <> mod <> "`, which imports:"
                            , indent $ toDoc (Array.fromFoldable importedOnes)
                            ]
                        )
                        (Map.toUnfoldable modules :: Array _)
                    )
                ]
            )
            (Map.toUnfoldable transitive)
            :: Array _
        )
    , Log.break
    , toDoc "Run the following command to install them all:"
    , indent $ toDoc
        $ "spago install -p "
        <> PackageName.print selected.package.name
        <> " "
        <> String.joinWith " " (map PackageName.print $ Set.toUnfoldable $ Map.keys transitive)
    ]

