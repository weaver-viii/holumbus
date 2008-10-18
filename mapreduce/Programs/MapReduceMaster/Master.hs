-- ----------------------------------------------------------------------------
{- |
  Module     : 
  Copyright  : Copyright (C) 2008 Stefan Schmidt
  License    : MIT

  Maintainer : Stefan Schmidt (stefanschmidt@web.de)
  Stability  : experimental
  Portability: portable
  Version    : 0.1


-}
-- ----------------------------------------------------------------------------

module Main(main) where

import Control.Exception

import           Holumbus.Common.Logging
import           Holumbus.Network.PortRegistry.PortRegistryPort
import qualified Holumbus.FileSystem.FileSystem as FS
import qualified Holumbus.Distribution.DMapReduce as MR
import qualified Holumbus.MapReduce.UserInterface as UI


version :: String
version = "Holumbus-Distribution Standalone-Master 0.1"


main :: IO ()
main
  = do
    putStrLn version
    handle (\e -> putStrLn $ "EXCEPTION: " ++ show e) $
      do
      initializeLogging
      p <- newPortRegistryFromXmlFile "/tmp/registry.xml"
      setPortRegistry p
      (mr,fs) <- initializeData
      UI.runUI mr version      
      deinitializeData (mr,fs)


initializeData :: IO (MR.DMapReduce, FS.FileSystem)
initializeData 
  = do    
    fs <- FS.mkFileSystemController FS.defaultFSControllerConfig
    let config  = MR.defaultMRMasterConfig
    mr <- MR.mkMapReduceMaster fs config
    return (mr,fs)


deinitializeData :: (MR.DMapReduce, FS.FileSystem) -> IO ()
deinitializeData (mr,fs)
  = do
    MR.closeMapReduce mr
    FS.closeFileSystem fs
