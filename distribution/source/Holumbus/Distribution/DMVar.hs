-- ----------------------------------------------------------------------------

{- |
  Module     : Holumbus.Distribution.DMVar 
  Copyright  : Copyright (C) 2009 Stefan Schmidt
  License    : MIT

  Maintainer : Stefan Schmidt (stefanschmidt@web.de)
  Stability  : experimental
  Portability: portable
  Version    : 0.1
  
  This module offers the distributed MVar datatype.

  The datatype behaves just like a normal MVar, but the content of the
  variable may be stored on a different DNode. When accessing the DMVar,
  the content will be fetched from the external node and written back.

  It is guaranteed, that only one node at a time can take the content
  of the DMVar. Just like normal DMVars, you can produce deadlocks.

  When a node dies which holds the content of a DMVar, the node which
  created the variable will reset its value to the last known value.
  
  If the owner dies, the other nodes cannot access the content of the
  DMVar any more.
-}

-- ----------------------------------------------------------------------------

module Holumbus.Distribution.DMVar
(
  -- * datatype
    DMVar

  -- * creating and closing DMVars
  , newDMVar
  , newEmptyDMVar
  , newRemoteDMVar
  , closeDMVar

  -- * acccessing DMVars
  , readDMVar
  , takeDMVar
  , putDMVar
)
where

import           Prelude hiding (catch)

import           Control.Concurrent.MVar
import           Data.Binary
import qualified Data.ByteString.Lazy as B
import           System.IO
import           System.Log.Logger

import           Holumbus.Distribution.DNode.Base


localLogger :: String
localLogger = "Holumbus.Distribution.DMVar"

dMVarType :: DResourceType
dMVarType = mkDResourceType "DMVAR"

mkDMVarEntry :: (Binary a) => DMVarReference a -> DResourceEntry
mkDMVarEntry d = DResourceEntry {
    dre_Dispatcher   = dispatchDMVarRequest d 
  }


data DMVarRequestMessage
  = DVMReqRead
  | DVMReqTake
  | DVMReqPut B.ByteString
  deriving (Show)
    
instance Binary DMVarRequestMessage where
  put(DVMReqRead)  = putWord8 1
  put(DVMReqTake)  = putWord8 2
  put(DVMReqPut b) = putWord8 3 >> put b
  get
    = do
      t <- getWord8
      case t of
        1 -> return (DVMReqRead)
        2 -> return (DVMReqTake)
        3 -> get >>= \b -> return (DVMReqPut b)
        _ -> error "DMVarRequestMessage: wrong encoding"


data DMVarResponseMessage
  = DVMRspRead B.ByteString
  | DVMRspTake B.ByteString
  | DVMRspPut
  deriving (Show)

instance Binary DMVarResponseMessage where
  put(DVMRspRead b) = putWord8 1 >> put b
  put(DVMRspTake b) = putWord8 2 >> put b
  put(DVMRspPut)    = putWord8 3
  get
    = do
      t <- getWord8
      case t of
        1 -> get >>= \b -> return (DVMRspRead b)
        2 -> get >>= \b -> return (DVMRspTake b)
        3 -> return (DVMRspPut)
        _ -> error "DMVarResponseMessage: wrong encoding"


dispatchDMVarRequest :: (Binary a) => DMVarReference a -> DNodeId -> Handle -> IO () 
dispatchDMVarRequest dch dna hdl
  = do
    debugM localLogger "dispatcher: getting message from handle"
    raw <- getByteStringMessage hdl
    let msg = (decode raw)
    debugM localLogger $ "dispatcher: Message: " ++ show msg
    case msg of
      (DVMReqRead)  -> handleRead dch hdl
      (DVMReqTake)  -> handleTake dch dna hdl
      (DVMReqPut b) -> handlePut dch (decode b) hdl


-- | The DMVar datatype.
data DMVar a
  = DMVarLocal DResourceAddress (MVar a) (MVar (a, Maybe DHandlerId))
  | DMVarRemote DResourceAddress

instance Binary (DMVar a) where
  put(DMVarLocal dra _ _) = put dra
  put(DMVarRemote dra)    = put dra
  get = get >>= \dra -> return (DMVarRemote dra)

data DMVarReference a = DMVarReference DResourceAddress (MVar a) (MVar (a, Maybe DHandlerId))
  

-- | Creates a new local DMVar with a start value.
--   The string parameter specifies the name of the variable.
--   If you leave it empty, a random value will be generated.
newDMVar :: (Binary a) => String -> a -> IO (DMVar a)
newDMVar s d
  = do
    dra <- genLocalResourceAddress dMVarType s
    v <- newMVar d
    o <- newEmptyMVar
    let dmv = (DMVarLocal dra v o)
        dvr = (DMVarReference dra v o)
        dve = (mkDMVarEntry dvr)
    addLocalResource dra dve
    return dmv


-- | Creates a new empty local DMVar. The string parameter specifies the name of
--   the variable. If you leave it empty, a random value will be generated.
newEmptyDMVar :: (Binary a) => String -> IO (DMVar a)
newEmptyDMVar s
  = do
    dra <- genLocalResourceAddress dMVarType s
    v <- newEmptyMVar
    o <- newMVar (undefined, Nothing)
    let dmv = (DMVarLocal dra v o)
        dvr = (DMVarReference dra v o)
        dve = (mkDMVarEntry dvr)
    addLocalResource dra dve
    return dmv


-- | Creates a reference to an external DMVar.
--   The first parameter is the name of the resource and the second one
--   the name of the node.
newRemoteDMVar :: String -> String -> IO (DMVar a)
newRemoteDMVar r n
  = do
    return $ DMVarRemote dra
    where
    dra = mkDResourceAddress dMVarType r n


-- | Closes a DMVar
closeDMVar :: (DMVar a) -> IO ()
closeDMVar (DMVarLocal dra _ _)
  = do
    delLocalResource dra
closeDMVar (DMVarRemote dra)
  = do
    delForeignResource dra



requestRead :: (Binary a) => Handle -> IO a
requestRead hdl
  = do
    putByteStringMessage (encode $ DVMReqRead) hdl
    raw <- getByteStringMessage hdl
    let rsp = (decode raw)
    case rsp of
      (DVMRspRead d) -> return $ decode d
      _ -> error "DMVar - requestRead: invalid response"


handleRead :: (Binary a) => DMVarReference a -> Handle -> IO ()
handleRead (DMVarReference _ v _) hdl
  = do
    a <- readMVar v
    putByteStringMessage (encode $ DVMRspRead $ encode a) hdl



requestTake :: (Binary a) => Handle -> IO a
requestTake hdl
  = do
    putByteStringMessage (encode $ DVMReqTake) hdl
    raw <- getByteStringMessage hdl
    let rsp = (decode raw)
    case rsp of
      (DVMRspTake d) -> return $ decode d
      _ -> error "DMVar - requestTake: invalid response"


handleTake :: (Binary a) => DMVarReference a -> DNodeId -> Handle -> IO ()
handleTake r@(DMVarReference _ v o) dni hdl
  = do
    debugM localLogger $ "handleTake: 1"
    a <- takeMVar v
    debugM localLogger $ "handleTake: 2"
    -- install handler and save backup
    mbDhi <- addForeignDNodeHandler False dni (handleErrorTake r)
    debugM localLogger $ "handleTake: 3"
    putMVar o (a, mbDhi)
    debugM localLogger $ "handleTake: 4"
    putByteStringMessage (encode $ DVMRspTake $ encode a) hdl
    debugM localLogger $ "handleTake: 5"
    

handleErrorTake :: (Binary a) => DMVarReference a -> DHandlerId -> IO ()
handleErrorTake (DMVarReference _ v o) dhi
  = do
    debugM localLogger $ "handleErrorTake: 1"
    (a,_ ) <- takeMVar o
    delForeignHandler dhi
    debugM localLogger $ "handleErrorTake: 2"
    putMVar v a


requestPut :: (Binary a) => a -> Handle -> IO ()
requestPut d hdl
  = do
    putByteStringMessage (encode $ DVMReqPut $ encode d) hdl
    raw <- getByteStringMessage hdl
    let rsp = (decode raw)
    case rsp of
      (DVMRspPut) -> return ()
      _ -> error "DMVar - requestWrite: invalid response"


handlePut :: (Binary a) => DMVarReference a -> a -> Handle -> IO ()
handlePut (DMVarReference _ v o) a hdl
  = do
    -- delete backup and kill handler 
    (_,mbDhi) <- takeMVar o
    case mbDhi of
      (Just dhi) -> delForeignHandler dhi
      (Nothing)  -> return ()
    putMVar v a
    putByteStringMessage (encode $ DVMRspPut) hdl



-- | Reads the content of a DMVar. Blocks if the Variable is empty.
--   This may throw an exception if the owner of the variable is unreachable.
readDMVar :: (Binary a) => DMVar a -> IO a
readDMVar (DMVarLocal _ v _)
  = do
    readMVar v
readDMVar (DMVarRemote a)
  = do
    unsafeAccessForeignResource a requestRead


-- | Takes the content of a DMVar. Blocks if the Variable is empty.
--   This may throw an exception if the owner of the variable is unreachable.
takeDMVar :: (Binary a) => DMVar a -> IO a
takeDMVar (DMVarLocal _ v o)
  = do
    a <- takeMVar v
    putMVar o (a, Nothing)
    return a
takeDMVar (DMVarRemote a)
  = do
    unsafeAccessForeignResource a requestTake


-- | Writes a value to the DMvar. Blocks if the Variable is not empty.
--   This may throw an exception if the owner of the variable is unreachable.
putDMVar :: (Binary a) => DMVar a -> a -> IO ()  
putDMVar (DMVarLocal _ v o) d
  = do
    (_,mbDhi) <- takeMVar o
    case mbDhi of
      (Just dhi) -> delForeignHandler dhi
      (Nothing)  -> return ()
    putMVar v d
putDMVar (DMVarRemote a) d
  = do
    unsafeAccessForeignResource a (requestPut d)

