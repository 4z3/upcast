{-# LANGUAGE QuasiQuotes, TemplateHaskell, OverloadedStrings, RecordWildCards, NamedFieldPuns #-}
{-# LANGUAGE ImplicitParams #-}

module Main where

import Upcast.Monad
import Options.Applicative

import System.Directory (removeFile)
import System.Posix.Env (getEnvDefault)
import System.Posix.Files (readSymbolicLink)
import System.FilePath.Posix

import Data.List (intercalate)
import qualified Data.Text as T
import Data.Text (Text(..))
import Data.Maybe (catMaybes, fromMaybe, isJust)
import qualified Data.Map as Map
import qualified Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B8

import Upcast.Types
import Upcast.IO
import Upcast.Interpolate (nl, n)
import Upcast.Nix
import Upcast.Infra
import Upcast.DeployCommands
import Upcast.Command
import Upcast.Temp
import Upcast.Environment
import Upcast.Install
import Upcast.Infra.Nix (infraRealmName)

evalInfraContext :: InfraCli -> NixContext -> IO InfraContext
evalInfraContext InfraCli{..} nix@NixContext{nix_expressionFile=file} = do
  info <- fgconsume_ (nixInfraInfo nix)
  value <- expectRight $ return $ nixInfras info
  return InfraContext{ inc_expressionFile = file
                     , inc_realmName = infraRealmName value
                     , inc_stateFile = fromMaybe (replaceExtension file "store") infraCli_stateFile
                     , inc_infras = value
                     }

icontext :: InfraCli -> IO InfraContext
icontext infraCli@InfraCli{..} =
  nixContext infraCli_expressionFile >>= evalInfraContext infraCli

infra :: InfraCli -> IO [Machine]
infra = icontext >=> evalInfra

infraDump :: InfraCli -> IO ()
infraDump = icontext >=> print . inc_infras

infraDebug :: InfraCli -> IO ()
infraDebug = icontext >=> debugEvalInfra >=> const (return ())

buildRemote :: BuildRemoteCli -> IO ()
buildRemote BuildRemoteCli{..} =
  nixContext brc_expressionFile >>= go >>= B8.putStrLn
  where
    remote = Remote Nothing brc_builder

    ssh_ = let ?sshConfig = Nothing in ssh
    fwd = fgrunDirect . ssh_ . forward remote
    copy = let ?sshConfig = Nothing in nixCopyClosureTo

    go :: NixContext -> IO B8.ByteString
    go NixContext{..} = do
      drv <- fgtmp $ nixInstantiate nix_args brc_attribute nix_expressionFile

      let query = [n|nix-store -qu #{drv}|]

      srsly "nix-copy-closure failed" . fgrunDirect $ copy brc_builder drv
      srsly "realise failed" . fwd $ nixRealise drv
      out <- fgconsume_ . ssh_ $ Cmd remote query "query"
      when brc_cat $ do
        fwd $ Cmd Local [n|cat #{out}|] "cat"
        return ()
      when (isJust brc_installProfile) $ do
        let Just prof = brc_installProfile
        fwd $ nixSetProfile prof (B8.unpack out)
        return ()
      return out

sshConfig :: InfraCli -> IO ()
sshConfig = infra >=> out . intercalate "\n" . fmap config
  where
    out s = putStrLn prefix >> putStrLn s

    identity (Just file) = T.concat ["\n    IdentityFile ", file, "\n"]
    identity Nothing = ""

    prefix = [nl|#
# this file is automatically generated using `upcast infra'
#
UserKnownHostsFile=/dev/null
StrictHostKeyChecking=no
|]

    config Machine{..} = [nl|
Host #{m_hostname}
    # #{m_instanceId}
    HostName #{m_publicIp}
    User root#{identity m_keyFile}
    ControlMaster auto
    ControlPath ~/.ssh/master-%r@%h:%p
    ForwardAgent yes
    ControlPersist 60s
|]

machine2nix :: Machine -> String
machine2nix Machine{..} = [nl|    "#{m_hostname}" = {
      instance-id = "#{m_instanceId}";
      public-ip = "#{m_publicIp}";
      private-ip = "#{m_privateIp}";
      key-file = #{case m_keyFile of Nothing -> "null"; Just x -> "\" ++ x ++ \""};
    };
|]

infraNix :: InfraCli -> IO ()
infraNix = infra >=> out . intercalate "\n" . fmap machine2nix
  where
    out s = putStrLn prefix >> putStrLn s >> putStrLn suffix

    prefix = [nl|#
# this file is automatically generated using `upcast infra'
#
{
  instances = {
|]

    suffix = "  };\n}\n"

printNixPath :: IO ()
printNixPath = do
  Just p <- nixPath
  putStrLn p

fgtmp :: (FilePath -> Command Local) -> IO FilePath
fgtmp f = do
  tmp <- randomTempFileName "fgtmp."
  let cmd@(Cmd _ _ tag) = f tmp
  expect ExitSuccess (tag <> " failed") $ fgrunDirect cmd
  dest <- readSymbolicLink tmp
  removeFile tmp
  return dest

main :: IO ()
main = do
    hSetBuffering stderr LineBuffering
    join $ customExecParser prefs opts
  where
    prefs = ParserPrefs { prefMultiSuffix = ""
                        , prefDisambiguate = True
                        , prefShowHelpOnError = True
                        , prefBacktrack = True
                        , prefColumns = 80
                        }

    exp = metavar "<expression file>"

    opts = (subparser cmds) `info` header "upcast - infrastructure orchestratrion"

    cmds = command "infra"
           (sshConfig <$> infraCliArgs `info`
            progDesc "evaluate infrastructure and output ssh_config(5)")

        <> command "infra-tree"
           (infraDump <$> infraCliArgs `info`
            progDesc "dump infrastructure tree in json format")

        <> command "infra-debug"
           (infraDebug <$> infraCliArgs `info`
            progDesc "evaluate infrastructure in debug mode")

        <> command "infra-nix"
           (infraNix <$> infraCliArgs `info`
            progDesc "evaluate infrastructure and print the nix description")

        <> command "build-remote"
           (buildRemote <$> buildRemoteCli `info`
            progDesc "forward nix-build to a remote host")

        <> command "nix-path"
           (pure printNixPath `info`
            progDesc "print effective path to upcast nix expressions")

        <> command "install"
           ((install fgrunDirect) <$> installCli `info`
            progDesc "copy a store path closure and set it to a profile")

    infraCliArgs = InfraCli
      <$> optional (strOption
                    (long "state"
                     <> short 's'
                     <> metavar "FILE"
                     <> help "use FILE as state file"))
      <*> argument str exp

    installCli = InstallCli
      <$> strOption (long "target"
                     <> short 't'
                     <> metavar "ADDRESS"
                     <> help "SSH-accessible host with Nix")
      <*> optional (strOption
                    (long "profile"
                     <> short 'p'
                     <> metavar "PROFILE"
                     <> help "set STORE_PATH to PROFILE (otherwise system)"))
      <*> optional (strOption
                    (long "ssh-config"
                     <> short 'c'
                     <> metavar "FILE"
                     <> help "use FILE as ssh_config(5)"))
      <*> optional (strOption
                    (long "pull"
                     <> short 'f'
                     <> metavar "FROM"
                     <> help "pull store paths from host"))
      <*> argument str (metavar "STORE_PATH")

    buildRemoteCli = BuildRemoteCli
      <$> strOption (long "target"
                    <> short 't'
                    <> metavar "ADDRESS"
                    <> help "SSH-accessible host with Nix")
      <*> optional (strOption (short 'A'
                     <> metavar "ATTRIBUTE"
                     <> help "build a specific attribute in the expression file"))
      <*> switch (long "print" <> short 'p' <> help "cat the derivation output file after build")
      <*> optional (strOption (short 'i'
                     <> metavar "PROFILE"
                     <> help "set the output store path to PROFILE on the target"))
      <*> argument str exp
