{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module MacInstaller
    ( main
    , SigningConfig(..)
    , signingConfig
    , signInstaller
    , importCertificate
    , deleteCertificate
    , run
    , run'
    ) where

---
--- An overview of Mac .pkg internals:    http://www.peachpit.com/articles/article.aspx?p=605381&seqNum=2
---

import           Universum

import           Control.Monad (unless)
import           Data.Text (Text)
import qualified Data.Text as T
import           System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, renameFile)
import           System.Environment (setEnv)
import           System.FilePath ((</>), FilePath)
import           System.FilePath.Glob (glob)
import           Filesystem.Path.CurrentOS (encodeString)
import qualified Filesystem.Path as P
import           Turtle (Shell, ExitCode (..), echo, proc, procs, inproc, shells, which, Managed, with, format, printf, (%), l, s, pwd, cd, sh, mktree)
import           Turtle.Line (unsafeTextToLine)

import           RewriteLibs (chain)

import           System.IO (hSetBuffering, BufferMode(NoBuffering))

import           Config
import           Types



main :: Options -> IO ()
main opts@Options{..} = do
  hSetBuffering stdout NoBuffering

  let appRoot = "../release/darwin-x64/Daedalus-darwin-x64/Daedalus.app"

  generateOSConfigs "./dhall" Macos64

  echo "Packaging frontend"
  shells "npm run package -- --icon installers/icons/256x256" mempty

  tempInstaller <- makeInstaller opts appRoot

  signInstaller signingConfig (toText tempInstaller) oOutput
  checkSignature oOutput

  run "rm" [toText tempInstaller]
  echo $ "Generated " <> unsafeTextToLine oOutput

  when (oTestInstaller == TestInstaller) $ do
    echo $ "--test-installer passed, will test the installer for installability"
    shells (format ("sudo installer -dumplog -verbose -target / -pkg \""%s%"\"") oOutput) empty

makeScriptsDir :: Options -> Managed T.Text
makeScriptsDir Options{..} = case oAPI of
  Cardano -> pure "data/scripts"
  ETC     -> pure "[DEVOPS-533]"

npmPackage :: Options -> Shell ()
npmPackage _ = do
  mktree "release"
  echo "~~~ Installing nodejs dependencies..."
  procs "npm" ["install"] empty
  liftIO $ setEnv "NODE_ENV" "production"
  echo "~~~ Running electron packager script..."
  procs "npm" ["run", "package"] empty
  size <- inproc "du" ["-sh", "release"] empty
  printf ("Size of Electron app is " % l % "\n") size

withDir :: P.FilePath -> IO a -> IO a
withDir d = bracket (pwd >>= \old -> (cd d >> pure old)) cd . const

makeInstaller :: Options -> FilePath -> IO FilePath
makeInstaller options@Options{..} appRoot = do
  let dir     = appRoot </> "Contents/MacOS"
      resDir  = appRoot </> "Contents/Resources"
  createDirectoryIfMissing False "dist"

  echo "Creating icons ..."
  procs "iconutil" ["--convert", "icns", "--output", "icons/electron.icns"
                   , "icons/electron.iconset"] mempty

  withDir ".." . sh $ npmPackage options

  echo "~~~ Preparing files ..."
  case oAPI of
    Cardano -> do
      -- Executables
      copyFile "cardano-launcher" (dir </> "cardano-launcher")
      copyFile "cardano-node" (dir </> "cardano-node")

      -- Config files
      copyFile "configuration.yaml"   (dir </> "configuration.yaml")
      copyFile "launcher-config.yaml" (dir </> "launcher-config.yaml")
      copyFile "log-config-prod.yaml" (dir </> "log-config-prod.yaml")
      copyFile "wallet-topology.yaml" (dir </> "wallet-topology.yaml")

      -- Genesis
      genesisFiles <- glob "*genesis*.json"
      procs "cp" (fmap toText (genesisFiles <> [dir])) mempty

      -- SSL
      copyFile "build-certificates-unix.sh" (dir </> "build-certificates-unix.sh")
      copyFile "ca.conf"     (dir </> "ca.conf")
      copyFile "server.conf" (dir </> "server.conf")
      copyFile "client.conf" (dir </> "client.conf")

      -- Rewrite libs paths and bundle them
      _ <- chain dir $ fmap toText [dir </> "cardano-launcher", dir </> "cardano-node"]
      pure ()
    _ -> pure () -- DEVOPS-533

  -- Prepare launcher
  de <- doesFileExist (dir </> "Frontend")
  unless de $ renameFile (dir </> "Daedalus") (dir </> "Frontend")
  run "chmod" ["+x", toText (dir </> "Frontend")]
  writeLauncherFile dir

  with (makeScriptsDir options) $ \scriptsDir -> do
    let
      pkgargs :: [ T.Text ]
      pkgargs =
           [ "--identifier"
           , "org."<> fromAppName oAppName <>".pkg"
           -- data/scripts/postinstall is responsible for running build-certificates
           , "--scripts", scriptsDir
           , "--component"
           , T.pack appRoot
           , "--install-location"
           , "/Applications"
           , "dist/temp.pkg"
           ]
    run "ls" [ "-ltrh", scriptsDir ]
    run "pkgbuild" pkgargs

  run "productbuild" [ "--product", "data/plist"
                     , "--package", "dist/temp.pkg"
                     , "dist/temp2.pkg"
                     ]

  run "rm" ["dist/temp.pkg"]
  pure "dist/temp2.pkg"

writeLauncherFile :: FilePath -> IO FilePath
writeLauncherFile dir = do
  writeFile path $ unlines contents
  run "chmod" ["+x", toText path]
  pure path
  where
    path = dir </> "Daedalus"
    contents =
      [ "#!/usr/bin/env bash"
      , "cd \"$(dirname $0)\""
      , "mkdir -p \"$HOME/Library/Application Support/Daedalus/Secrets-1.0\""
      , "mkdir -p \"$HOME/Library/Application Support/Daedalus/Logs/pub\""
      , "./cardano-launcher"
      ]

data SigningConfig = SigningConfig
  { signingIdentity         :: T.Text
  , signingKeyChain         :: Maybe T.Text
  , signingKeyChainPassword :: Maybe T.Text
  } deriving (Show, Eq)

signingConfig :: SigningConfig
signingConfig = SigningConfig
  { signingIdentity = "Developer ID Installer: Input Output HK Limited (89TW38X994)"
  , signingKeyChain = Nothing
  , signingKeyChainPassword = Nothing
  }

-- | Runs "security import -x"
importCertificate :: SigningConfig -> FilePath -> Maybe Text -> IO ExitCode
importCertificate SigningConfig{..} cert password = do
  let optArg s = map toText . maybe [] (\p -> [s, p])
      certPass = optArg "-P" password
      keyChain = optArg "-k" signingKeyChain
  productSign <- optArg "-T" . fmap (toText . encodeString) <$> which "productsign"
  let args = ["import", toText cert, "-x"] ++ keyChain ++ certPass ++ productSign
  -- echoCmd "security" args
  proc "security" args mempty

--- | Remove our certificate from the keychain
deleteCertificate :: SigningConfig -> IO ExitCode
deleteCertificate SigningConfig{..} = run' "security" args
  where
    args = ["delete-certificate", "-c", signingIdentity] ++ keychain
    keychain = maybe [] pure signingKeyChain

-- | Creates a new installer package with signature added.
signInstaller :: SigningConfig -> T.Text -> T.Text -> IO ()
signInstaller SigningConfig{..} src dst =
  run "productsign" $ sign ++ keychain ++ [ src, dst ]
  where
    sign = [ "--sign", signingIdentity ]
    keychain = maybe [] (\k -> [ "--keychain", k]) signingKeyChain

-- | Use pkgutil to verify that signing worked.
checkSignature :: T.Text -> IO ()
checkSignature pkg = run "pkgutil" ["--check-signature", pkg]

-- | Print the command then run it. Raises an exception on exit
-- failure.
run :: T.Text -> [T.Text] -> IO ()
run cmd args = do
    echoCmd cmd args
    procs cmd args mempty

-- | Print the command then run it.
run' :: T.Text -> [T.Text] -> IO ExitCode
run' cmd args = do
    echoCmd cmd args
    proc cmd args mempty

echoCmd :: T.Text -> [T.Text] -> IO ()
echoCmd cmd args = echo . unsafeTextToLine $ T.intercalate " " (cmd : args)
