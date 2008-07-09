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

import Holumbus.Common.Logging
import Holumbus.Network.Site
import qualified Holumbus.Network.Port as Port
import qualified Holumbus.Distribution.Distribution as D
import qualified Holumbus.Distribution.Master.MasterPort as MP
import qualified Holumbus.Distribution.UserInterface as UI 

    
version :: String
version = "Holumbus-Distribution Standalone-Client 0.1"


main :: IO ()
main
  = do
    putStrLn version
    handle (\e -> putStrLn $ "EXCEPTION: " ++ show e) $
      do
      initializeLogging      
      d <- initializeData
      UI.runUI d version      
      deinitializeData d


initializeData :: IO (D.Distribution)
initializeData 
  = do
    sid <- getSiteId
    putStrLn $ "initialising master on site" ++ show sid 
    putStrLn "-> master-port"
    p <- Port.readPortFromFile "master.port"
    let mp = (MP.newMasterPort p)    
    putStrLn "-> fileSystem"
    d <- D.newDistribution mp
    return d


deinitializeData :: D.Distribution -> IO ()
deinitializeData d
  = do
    D.closeDistribution d
    