{-# LANGUAGE CPP, RecordWildCards #-}

module Main where

import           Control.Monad
import           Data.IORef
import           Data.List
import           Data.List.Split (splitOn)
import           Data.Maybe
import qualified Data.Version as V(showVersion)
import           Distribution.InstalledPackageInfo (exposedName, exposedModules, InstalledPackageInfo)
import           Distribution.ModuleName (ModuleName)
import qualified Distribution.ModuleName as MN
import           Distribution.Package (UnitId, unUnitId, installedUnitId, packageId, pkgName)
import qualified Distribution.PackageDescription as PD
import           Distribution.Simple.Compiler
import           Distribution.Simple.Configure (tryGetPersistBuildConfig, ConfigStateFileError(..)
                                               ,localBuildInfoFile, checkPersistBuildConfigOutdated)
import           Distribution.Simple.LocalBuildInfo
import           Distribution.Simple.PackageIndex (lookupUnitId, PackageIndex)
import           Distribution.Simple.Utils (cabalVersion)
import           Distribution.Text (display)
import           Distribution.Types.ForeignLib(ForeignLib(..))
import           Distribution.Types.LibraryName
import           Distribution.Types.MungedPackageId(MungedPackageId(..))
import           Distribution.Types.UnqualComponentName(unUnqualComponentName)
import           Distribution.Version(mkVersion)
import qualified Language.Haskell.Exts as H
import           Options.Applicative
import           Options.Applicative.Help.Pretty (Doc)
import qualified Options.Applicative.Help.Pretty as P
import           System.Directory (getModificationTime, getDirectoryContents, doesDirectoryExist, doesFileExist, getCurrentDirectory)
import           System.Exit (exitFailure)
import           System.FilePath ((</>), takeDirectory)
import           System.Process

import           Paths_packunused (version)

-- | CLI Options
data Opts = Opts
    { ignoreEmptyImports :: Bool
    , ignoreMainModule :: Bool
    , ignoredPackages :: [String]
    } deriving (Show)

opts :: Parser Opts
opts = Opts <$> switch (long "ignore-empty-imports" <> help "ignore empty .imports files")
            <*> switch (long "ignore-main-module" <> help "ignore Main modules")
            <*> many (strOption (long "ignore-package" <> metavar "PKG" <>
                                 help "ignore the specfied package in the report"))

usageFooter :: Doc
usageFooter = mconcat
    [ P.text "Tool to help find redundant build-dependencies in CABAL projects", P.linebreak
    , P.hardline
    , para $ "In order to use this tool you should set up the package to be analyzed as follows, " ++
             "before executing 'packunused':", P.linebreak

    , P.hardline
    , P.text "For cabal:"
    , P.indent 2 $ P.vcat $ P.text <$>
      [ "cabal clean"
      , "rm *.imports        # (only needed for GHC<7.8)"
      , "cabal configure -O0 --disable-library-profiling"
      , "cabal build --ghc-option=-ddump-minimal-imports"
      , "packunused"
      ]

    , P.linebreak, P.hardline
    , P.text "For stack:"
    , P.indent 2 $ P.vcat $ P.text <$>
      [ "stack clean"
      , "stack build --ghc-options=-ddump-minimal-imports"
      , "packunused"
      ]

    , P.linebreak, P.hardline
    , P.text "Note:" P.<+> P.align
      (para $ "The 'cabal configure' command above only tests the default package configuration. " ++
              "You might need to repeat the process with different flags added to the 'cabal configure' step " ++
              "(such as '--enable-tests' or '--enable-benchmark' or custom cabal flags) " ++
              "to make sure to check all configurations")
    , P.linebreak, P.hardline
    , P.text "Report bugs to https://github.com/hvr/packunused/issues"
    ]
  where
    para = P.fillSep . map P.text . words

usageHeader :: String
usageHeader = "packunused " ++ V.showVersion version ++
             " (using Cabal "++ show cabalVersion ++ ")"

getInstalledPackageInfos :: [(UnitId, MungedPackageId)] -> PackageIndex InstalledPackageInfo -> [InstalledPackageInfo]
getInstalledPackageInfos pkgs ipkgs =
    [ ipi
    | (ipkgid, _) <- pkgs
    , not (isInPlacePackage ipkgid)
    , Just ipi <- [lookupUnitId ipkgs ipkgid]
    ]
  where
    isInPlacePackage :: UnitId -> Bool
    isInPlacePackage u =
        "-inplace" `isSuffixOf` unUnitId u

chooseDistPref :: Bool -> IO String
chooseDistPref useStack =
  if useStack
    then takeWhile (/= '\n') <$> readProcess "stack" (words "path --dist-dir") ""
    else return "dist"

getLbi :: Bool -> FilePath -> IO LocalBuildInfo
getLbi useStack distPref = either explainError id <$> tryGetPersistBuildConfig distPref
  where
    explainError :: ConfigStateFileError -> a
    explainError x@ConfigStateFileBadVersion{} | useStack = stackExplanation x
    explainError x = error ("Error: " ++ show x)
    stackExplanation x = error ("Error: " ++ show x ++ "\n\nYou can probably fix this by running:\n  stack setup --upgrade-cabal")

main :: IO ()
main = do
    Opts {..} <- execParser $
                 info (helper <*> opts)
                      (header usageHeader <>
                       fullDesc <>
                       footerDoc (Just usageFooter))

    -- print opts'

    useStack <- findRecursive "stack.yaml"
    distPref <- chooseDistPref useStack

    lbiExists <- doesFileExist (localBuildInfoFile distPref)
    unless lbiExists $ do
        putStrLn "*ERROR* package not properly configured yet or not in top-level CABAL project folder; see --help for more details"
        exitFailure

    lbiMTime <- getModificationTime (localBuildInfoFile distPref)
    lbi <- getLbi useStack distPref

    -- minory sanity checking
    case pkgDescrFile lbi of
        Nothing -> fail "could not find .cabal file"
        Just pkgDescFile -> do
            res <- checkPersistBuildConfigOutdated distPref pkgDescFile
            when res $ putStrLn "*WARNING* outdated config-data -- please re-configure"

    let cbo = map
          (\x -> case x of
              LibComponentLocalBuildInfo {componentLocalName = n} -> n
              FLibComponentLocalBuildInfo {componentLocalName = n} -> n
              ExeComponentLocalBuildInfo {componentLocalName = n} -> n
              TestComponentLocalBuildInfo {componentLocalName = n} -> n
              BenchComponentLocalBuildInfo {componentLocalName = n} -> n
              ) $ allComponentsInBuildOrder lbi
        pkg = localPkgDescr lbi
        ipkgs = installedPkgs lbi

    importsInOutDir <- case compilerId (compiler lbi) of
        CompilerId GHC v | v >= mkVersion [7,8] -> return True
        CompilerId GHC _ -> return False
        CompilerId _ _ -> putStrLn "*WARNING* non-GHC compiler detected" >> return False

    putHeading "detected package components"

    when (isJust $ PD.library pkg) $
        putStrLn $ " - library" ++ [ '*' | CLibName LMainLibName `notElem` cbo ]

    unless (null $ PD.subLibraries pkg) $
        putStrLn $ " - sub lib(s): " ++ unwords [ showLibraryName mayN ++ [ '*' | flip notElem cbo (CLibName mayN) ]
                                                   | PD.Library { libName = mayN } <- PD.subLibraries pkg ]
    unless (null $ PD.foreignLibs pkg) $
        putStrLn $ " - foreign lib(s): " ++ unwords [ unUnqualComponentName n ++ [ '*' | CFLibName n `notElem` cbo ]
                                                   | ForeignLib { foreignLibName = n } <- PD.foreignLibs pkg ]
    unless (null $ PD.executables pkg) $
        putStrLn $ " - executable(s): " ++ unwords [ unUnqualComponentName n ++ [ '*' | CExeName n `notElem` cbo ]
                                                   | PD.Executable { exeName = n } <- PD.executables pkg ]
    unless (null $ PD.testSuites pkg) $
        putStrLn $ " - testsuite(s): " ++ unwords [ unUnqualComponentName n ++ [ '*' | CTestName n `notElem` cbo ]
                                                  | PD.TestSuite { testName = n } <- PD.testSuites pkg ]
    unless (null $ PD.benchmarks pkg) $
        putStrLn $ " - benchmark(s): " ++ unwords [ unUnqualComponentName n ++ [ '*' | CBenchName n `notElem` cbo ]
                                                  | PD.Benchmark { benchmarkName = n} <- PD.benchmarks pkg ]

    putStrLn ""
    putStrLn "(component names suffixed with '*' are not configured to be built)"
    putStrLn ""

    ----------------------------------------------------------------------------

    -- GHC prior to 7.8.1 emitted .imports file in $PWD and therefore would risk overwriting files
    let multiMainIssue = not importsInOutDir && length (filter (/= CLibName LMainLibName) cbo) > 1


    ok <- newIORef True

    -- handle stanzas
    withAllComponentsInBuildOrder pkg lbi $ \c clbi -> do
        let (n,n2,cmods) = componentNameAndModules (not ignoreMainModule) c
            outDir = if null n2 then buildDir lbi else buildDir lbi </> n2 </> n2++"-tmp"
            outDir' = if importsInOutDir then outDir else  "."

        -- import dependancy graph read in via '.imports' files
        mods <- mapM (readImports outDir') =<< findImportsFiles outDir' lbiMTime

        -- imported modules by component
        let allmods | ignoreEmptyImports  = nub [ m | (mn, imps) <- mods
                                                    , mn `elem` cmods
                                                    , (m,_:_) <- imps
                                                    ]
                    | otherwise           = nub [ m | (mn, imps) <- mods
                                                    , mn `elem` cmods
                                                    , (m,_) <- imps
                                                    ]

            ipinfos = getInstalledPackageInfos (componentPackageDeps clbi) ipkgs

            (ignored, unignored) = partition (\x -> display (pkgName $ packageId x) `elem` ignoredPackages) ipinfos

            unused :: [UnitId]
            unused = [ installedUnitId ipinfo
                     | ipinfo <- unignored
                     , let expmods = map exposedName $ exposedModules ipinfo
                     , not (any (`elem` allmods) expmods)
                     ]

            missingMods = cmods \\ map fst mods

        -- print out redundant package ids (if any)
        putHeading n

        unless (null missingMods) $ do
            putStrLn "*WARNING* dependency information for the following component module(s) is missing: "
            forM_ missingMods $ \m -> putStrLn $ " - " ++ display m
            putStrLn ""

        when (not ignoreMainModule && multiMainIssue && not (compIsLib c)) $ do
            putStrLn "*WARNING* multiple non-library components detected"
            putStrLn "  result may be unreliable if there are multiple non-library components because the 'Main.imports' file gets overwritten with GHC prior to version 7.8.1, try"
            putStrLn ""
            putStrLn $ "  rm "++(outDir </> "Main.h")++"; cabal build --ghc-option=-ddump-minimal-imports; packunused"
            putStrLn ""
            putStrLn "  to get a more accurate result for this component."
            putStrLn ""

        unless (null ignored) $ do
            let k = length ignored
            putStrLn $ "Ignoring " ++ show k ++ " package" ++ (if k == 1 then "" else "s")
            putStrLn ""

        if null unused
          then do
            putStrLn "no redundant packages dependencies found"
            putStrLn ""
          else do
            putStrLn "The following package dependencies seem redundant:"
            putStrLn ""
            forM_ unused $ \pkg' -> putStrLn $ " - " ++ display pkg'
            putStrLn ""
            writeIORef ok False

    whenM (not <$> readIORef ok) exitFailure
  where
    compIsLib CLib {} = True
    compIsLib _       = False

    findImportsFiles outDir lbiMTime = do
        whenM (not `fmap` doesDirectoryExist outDir) $
            fail $"output-dir " ++ show outDir ++ " does not exist; -- has 'cabal build' been performed yet? (see also 'packunused --help')"

        files <- filterM (doesFileExist . (outDir</>)) =<<
                 liftM (sort . filter (isSuffixOf ".imports"))
                 (getDirectoryContents outDir)

        when (null files) $
            fail $ "no .imports files found in " ++ show outDir ++ " -- has 'cabal build' been performed yet? (see also 'packunused --help')"

        -- .import files generated after lbi
        files' <- filterM (liftM (> lbiMTime) . getModificationTime . (outDir</>)) files

        unless (files' == files) $ do
            putStrLn "*WARNING* some possibly outdated .imports were found (please consider removing/rebuilding them):"
            forM_ (files \\ files') $ \fn -> putStrLn $ " - " ++ fn
            putStrLn ""

        -- when (null files') $
        --    fail "no up-to-date .imports files found -- please perform 'cabal build'"

        return files

componentNameAndModules :: Bool -> Component -> (String, String, [ModuleName])
componentNameAndModules addMainMod c  = (n, n2, m)
  where
    m = nub $ sort $ m0 ++ PD.otherModules (componentBuildInfo c)

    (n, n2, m0) = case c of
        CLib   ci -> ("library", "", PD.exposedModules ci)
        CFLib  ci -> let name = unUnqualComponentName (foreignLibName ci)
                     in ("foreignLib("++name++")", name, [mainModName | addMainMod ])
        CExe   ci -> let name = unUnqualComponentName (PD.exeName ci)
                     in ("executable("++name++")", name, [mainModName | addMainMod ])
        CBench ci -> let name = unUnqualComponentName (PD.benchmarkName ci)
                     in ("benchmark("++name++")", name, [mainModName | addMainMod ])
        CTest  ci -> let name = unUnqualComponentName (PD.testName ci)
                     in ("testsuite("++name++")", name, [mainModName | addMainMod ])

    mainModName = MN.fromString "Main"

putHeading :: String -> IO ()
putHeading s = do
    putStrLn s
    putStrLn (replicate (length s) '~')
    putStrLn ""

-- empty symbol list means '()'
readImports :: FilePath -> FilePath -> IO (ModuleName, [(ModuleName, [String])])
readImports outDir fn = do
    unless (".imports" `isSuffixOf` fn) $
        fail ("argument "++show fn++" doesn't have .imports extension")

    let m = MN.fromString $ take (length fn - length ".imports") fn

    contents <- readFile (outDir </> fn)
    case parseImportsFile contents of
        (H.ParseOk (H.Module _ _ _ imps _)) -> do
            let imps' = [ (MN.fromString mn, extractSpecs (H.importSpecs imp))
                        | imp <- imps, let H.ModuleName _ mn = H.importModule imp ]

            return (m, imps')
        (H.ParseOk (H.XmlPage _ _ _ _ _ _ _)) -> do
            putStrLn "*ERROR* .imports file is invalid file type"
            exitFailure
        (H.ParseOk (H.XmlHybrid _ _ _ _ _ _ _ _ _)) -> do
            putStrLn "*ERROR* .imports file is invalid file type"
            exitFailure
        H.ParseFailed loc msg -> do
            putStrLn "*ERROR* failed to parse .imports file"
            putStrLn $ H.prettyPrint loc ++ ": " ++ msg
            exitFailure

  where
    extractSpecs :: Maybe (H.ImportSpecList s) -> [String]
    extractSpecs (Just (H.ImportSpecList _ _ impspecs)) = map H.prettyPrint impspecs
    extractSpecs _ = error "unexpected import specs"

    parseImportsFile = H.parseFileContentsWithMode (H.defaultParseMode { H.extensions = exts, H.parseFilename = outDir </> fn }) . stripExplicitNamespaces . stripSafe

    -- hack to remove -XExplicitNamespaces until haskell-src-exts supports that
    stripExplicitNamespaces = unwords . splitOn " type "
    stripSafe = unwords . splitOn " safe "

    exts = map H.EnableExtension [ H.PatternSynonyms, H.MagicHash, H.PackageImports, H.CPP, H.TypeOperators, H.TypeFamilies, H.ExplicitNamespaces ]

-- | Find if a file exists in the current directory or any of its
-- parents.
findRecursive :: FilePath -> IO Bool
findRecursive f = do
  dir <- getCurrentDirectory
  go dir
  where
    go dir = do
      exists <- doesFileExist (dir </> f)
      if exists
      then return exists
      else
        let parent = takeDirectory dir
        in if parent == dir
           then return False
           else go parent

whenM :: Monad m => m Bool -> m () -> m ()
whenM test = (test >>=) . flip when
