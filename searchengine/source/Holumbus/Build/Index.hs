-- ----------------------------------------------------------------------------

{- |
  Module     : Holumbus.Build.Crawl
  Copyright  : Copyright (C) 2008 Sebastian M. Schlatt
  License    : MIT
  
  Maintainer : Sebastian M. Schlatt (sms@holumbus.org)
  Stability  : experimental
  Portability: portable
  Version    : 0.1
  
  Indexer functions

-}

-- -----------------------------------------------------------------------------
{-# OPTIONS -XFlexibleContexts #-}
-- -----------------------------------------------------------------------------

module Holumbus.Build.Index 
  (
  -- * Building indexes
    buildIndex
  , buildIndexM
  
  -- * Indexer Configuration
  , IndexerConfig (..)
  , ContextConfig (..)
  , mergeIndexerConfigs
  
  , getTexts
  )

where

-- import           Data.List
import qualified Data.Map    as M
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import           Data.Maybe

-- import           Control.Exception
-- import           Control.Monad

import           Holumbus.Build.Config
import           Holumbus.Control.MapReduce.MapReducible
import           Holumbus.Control.MapReduce.ParallelWithClass 
import           Holumbus.Index.Common
import           Holumbus.Utility

import           System.Time

import           Text.XML.HXT.Core

-- -----------------------------------------------------------------------------

buildIndex :: (HolDocuments d a, HolIndex i, HolCache c, MapReducible i (Context, Word) Occurrences) => 
              Int                -- ^ Number of parallel threads for MapReduce
           -> Int                -- ^ TraceLevel for Arrows
           -> d a                -- ^ List of input Data
           -> IndexerConfig      -- ^ Configuration for the Indexing process
           -> i                  -- ^ An empty HolIndex. This is used to determine which kind of index to use.
           -> Maybe c
           -> IO i               -- ^ returns a HolIndex
buildIndex workerThreads traceLevel docs idxConfig emptyIndex cache
  = let docs' =  (map (\(i,d) -> (i, uri d)) (IM.toList $ toMap docs)) in
       -- assert ((sizeWords emptyIndex) == 0) 
                 (mapReduce 
                    workerThreads
--                    (ic_indexerTimeOut idxConfig)
--                    (( fromMaybe "/tmp/" (ic_tempPath idxConfig)) ++ "MapReduce.db")
                    emptyIndex
                    (computeOccurrences traceLevel 
                              (isJust $ ic_tempPath idxConfig)
                              (ic_contextConfigs idxConfig) 
                              (ic_readAttributes idxConfig)
                              cache
                    )
                    docs'
                 )


buildIndexM :: (HolDocuments d a, HolIndexM m i, HolCache c, MapReducible i (Context, Word) Occurrences) => 
              Int                -- ^ Number of parallel threads for MapReduce
           -> Int                -- ^ TraceLevel for Arrows
           -> d a                -- ^ List of input Data
           -> IndexerConfig      -- ^ Configuration for the Indexing process
           -> i                  -- ^ An empty HolIndexM. This is used to determine which kind of index to use.
           -> Maybe c            -- ^ Just HolCache switches cache construction on
           -> IO i               -- ^ returns a HolIndexM
buildIndexM workerThreads traceLevel docs idxConfig emptyIndex cache
  = let docs' =  (map (\(i,d) -> (i, uri d)) (IM.toList $ toMap docs)) in
       -- assert ((sizeWords emptyIndex) == 0) 
                 (mapReduce 
                    workerThreads
--                    (ic_indexerTimeOut idxConfig)
--                    (( fromMaybe "/tmp/" (ic_tempPath idxConfig)) ++ "MapReduce.db")
                    emptyIndex
                    (computeOccurrences traceLevel 
                              (isJust $ ic_tempPath idxConfig)
                              (ic_contextConfigs idxConfig) 
                              (ic_readAttributes idxConfig)
                              cache
                    )
                    docs'
                 )



-- | The MAP function in a MapReduce computation for building indexes.
--   The first three parameters have to be passed to the function to receive
--   a function with a valid MapReduce-map signature.
--
--   The function optionally outputs some debug information and then starts
--   the processing of a file by passing it together with the configuration
--   for different contexts to the @processDocument@ function where the file
--   is read and then the interesting parts configured in the
--   context configurations are extracted.

computeOccurrences :: HolCache c =>
               Int -> Bool -> [ContextConfig] -> SysConfigList -> Maybe c  
            -> DocId -> String -> IO [((Context, Word), Occurrences)]
computeOccurrences traceLevel fromTmp contextConfigs attrs cache docId theUri
    = do
      clt <- getClockTime
      cat <- toCalendarTime clt
      res <- runX (     setTraceLevel traceLevel
                    >>> traceMsg 1 ((calendarTimeToString cat) ++ " - indexing document: " 
                                                               ++ show docId ++ " -> "
                                                               ++ show theUri)
                    >>> processDocument traceLevel attrs' contextConfigs cache docId theUri
--                    >>> arr (\ (c, w, d, p) -> (c, (w, d, p)))
                    >>> strictA
             )
      return $ buildPositions res 
    where
    attrs' = if fromTmp then attrs ++ standardReadTmpDocumentAttributes else attrs
    buildPositions :: [(Context, Word, DocId, Position)] -> [((Context, Word),  Occurrences)]
    buildPositions l = M.foldWithKey (\(c,w,d) ps acc -> ((c,w),IM.singleton d ps) : acc) [] $
      foldl (\m (c,w,d,p) -> M.insertWith IS.union (c,w,d) (IS.singleton p) m) M.empty l 
                             

-- -----------------------------------------------------------------------------
    
-- | Downloads a document and calls the function to process the data for the
--   different contexts of the index
processDocument :: HolCache c =>  
     Int
  -> SysConfigList
  -> [ContextConfig]
  -> Maybe c
  -> DocId 
  -> URI
  -> IOSLA (XIOState s) b (Context, Word, DocId, Position)
processDocument traceLevel attrs ccs cache docId theUri =
        withTraceLevel (traceLevel - traceOffset) (readDocument attrs theUri)
    >>> (catA $ map (processContext cache docId) ccs )   -- process all context configurations  
    


-- | Process a Context. Applies the given context configuration to extract information from
--   the XmlTree that is passed in the arrow.
processContext :: 
  ( HolCache c) => 
     Maybe c
  -> DocId
  -> ContextConfig
  -> IOSLA (XIOState s) XmlTree (Context, Word, DocId, Position)

processContext cache docId cc
    = cc_preFilter cc                                         -- convert XmlTree
      >>>
      fromLA extractWords
      >>>
      ( if ( isJust cache
             &&
             cc_addToCache cc
           )
        then perform (arrIO storeInCache)
        else this
      )
      >>>
      arrL genWordList
      >>>
      strictA
    where
    extractWords  :: LA XmlTree [String]
    extractWords
      = listA
        ( xshow ( (cc_fExtract cc)                           -- extract interesting parts
                  >>>
                  getTexts
                )
          >>>
          arrL ( filter (not . null) . cc_fTokenize cc )
        )

    genWordList   :: [String] -> [(Context, Word, DocId, Position)]
    genWordList
      = zip [1..]                                           -- number words
        >>>                                                 -- arrow for pure functions
        filter (not . (cc_fIsStopWord cc) . snd)            -- delete boring words
        >>>
        map ( \ (p, w) -> (cc_name cc, w, docId, p) )       -- attach context and docId

    storeInCache s
      = let
        t = unwords s
        in 
        if t /= ""
           then putDocText (fromJust cache) (cc_name cc) docId t
           else return ()

getTexts  :: LA XmlTree XmlTree
getTexts                                                      -- select all text nodes
    =  choiceA
       [ isText :-> this                                      -- take the text nodes
       , isElem :-> ( space                                   -- substitute tags by a single space
                      <+>                                     -- so tags act as word delimiter
                      (getChildren >>> getTexts)
                      <+>
                      space
                    )                                         -- tags are interpreted as word delimiter
       , isAttr :-> ( getChildren >>> getTexts )              -- take the attribute value
       , this   :-> none                                      -- ignore anything else
       ]
    where
    space = txt " "
            
            
{-
 -- older and slower version. only for sentimentality
processContext cache docId cc  = 
        (cc_preFilter cc)                                     -- convert XmlTree
    >>> listA (
                    (cc_fExtract cc)               -- extract interesting parts
                >>> deep isText                               -- Search deep for text nodes
                >>> getText 
              )
    >>> arr concat                                            -- convert text nodes into strings
    >>> arr (cc_fTokenize cc)                                 -- apply tokenizer function
    >>> arr (filter (\w -> w /= ""))                          -- filter empty words
    >>> perform ( (const $ (isJust cache) && (cc_addToCache cc)) -- write cache data if configured
                  `guardsP` 
                   ( arr unwords >>> arrIO ( putDocText (fromJust cache) (cc_name cc) docId)) 
                )    
    >>> arr (zip [1..])                                       -- number words
    >>> arr (filter (\(_,s) -> not ((cc_fIsStopWord cc) s)))  -- remove stop words
    >>> arrL (map (\(p, w) -> (cc_name cc, w, docId, p) ))    -- make a list of result tupels
    >>> strictA                                               -- force strict evaluation
               
 -}    
