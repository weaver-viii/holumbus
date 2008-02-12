-- ----------------------------------------------------------------------------

{- |
  Module     : Holumbus.Index.Cache
  Copyright  : Copyright (C) 2008 Timo B. Huebel
  License    : MIT

  Maintainer : Timo B. Huebel (t.h@gmx.info)
  Stability  : experimental
  Portability: portable
  Version    : 0.1

  A persistent full-text cache for arbitrary documents. Implemented on 
  top of @unsafePerformIO@ to be able to provide a purely functional
  interface but still be able to store the documents on some persistent
  memory. This could bee seen as a map with its storage capacity being
  extended by persistent storage.

-}

-- ----------------------------------------------------------------------------

module Holumbus.Index.Cache 
  (
  -- * Cache types
  Cache
  
  -- * Construction
  , createCache
  )
where

import System.IO
import System.IO.Unsafe

import Control.Exception

import Data.IntMap (IntMap)
import qualified Data.IntMap as IM

import Holumbus.Index.Common

-- | A simple document cache based on plain text files in a single directory.
data Cache = Cache FilePath deriving (Show, Eq)

instance HolCache Cache where
  getDocText (Cache s) c d = 
    unsafePerformIO (handle (\_ -> return "") (readFile (s ++ "/" ++ getName c d)))

  putDocText (Cache s) c d t = 
    unsafePerformIO (handle (\_ -> return ()) (writeFile (s ++ "/" ++ getName c d) t)) `seq` Cache s   
    
-- | Creates a new document cache from the given directory. Depending on the directory contents,
-- the cache contains some documents or is empty.
createCache :: FilePath -> Cache
createCache f = Cache f

-- | Create a unique file identifier from context and document id.
getName :: Context -> DocId -> FilePath
getName c d = (show d) ++ "-" ++ c
