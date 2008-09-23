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
{-# OPTIONS -fglasgow-exts #-}
-- -----------------------------------------------------------------------------

module Examples.Crawler.Index 
  (
    indexerOccurrencesAction
  , indexerBuildIndexAction
  -- * Building indexes
  , buildIndex
  -- , buildIndexM
  
  -- * Indexer Configuration
  , IndexerConfig (..)
  -- , ContextConfig (..)
  -- , mergeIndexerConfigs
  
  -- , getTexts
  )

where

import           Data.List
import           Data.Binary hiding (Word)
import qualified Data.Map    as M
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import           Data.Maybe

-- import           Control.Exception
import           Control.Monad
import           Control.Parallel.Strategies

import           Holumbus.Build.Config
-- import           Holumbus.Control.MapReduce.ParallelWithClass 
import           Holumbus.Index.Common
import           Holumbus.Index.Inverted.Memory
import           Holumbus.Utility

import           System.Time

import           Text.XML.HXT.Arrow hiding (getXPathTrees)     -- import all stuff for parsing, validating, and transforming XML

import qualified Holumbus.FileSystem.FileSystem as FS
import           Holumbus.MapReduce.Types
import           Holumbus.MapReduce.MapReduce


import           Examples.Crawler.Config


indexerOccurrencesAction
  :: MRCrawlerConfig d a
  -> ActionConfiguration 
       ()                         -- state
       DocId String               -- k1, v1
       (Context,Word) Occurrences -- k2, v2
       Occurrences                -- v3 == v2
       Occurrences                -- v4
indexerOccurrencesAction cc
  = -- readActionConfiguration $
      (defaultActionConfiguration "INDEX_OCCURRENCES")
        { ac_Map     = Just mapAction
        , ac_Combine = Nothing
        , ac_Reduce  = Just reduceAction
        }
    where
      mapAction 
        = (defaultMapConfiguration (mapIndex cc))
            { mc_Partition = mapPartitionIndex }
      reduceAction
        = (defaultReduceConfiguration (reduceOccurrences))
            {{- rc_Merge     = mergeIndex -} 
             rc_Partition = reducePartitionOccurrences }

mapIndex 
  :: MRCrawlerConfig d a
  -> ActionEnvironment -> ()
  -> DocId -> String
  -> IO [((Context, Word), Occurrences)]
mapIndex cc env _ docId theUri
  = do
    let idxConfig      = cc_IndexerConfig cc
        traceLevel     = cc_TraceLevel cc
        fromTmp        = (isJust $ ic_tempPath idxConfig)
        contextConfigs = (ic_contextConfigs idxConfig)
        attrs          = (ic_readAttributes idxConfig)
        fileSystem     = ae_FileSystem env
    computeOccurrences traceLevel fileSystem fromTmp contextConfigs attrs {- cache -} docId theUri


mapPartitionIndex
  :: ActionEnvironment -> ()
  -> Int -> [((Context, Word), Occurrences)]
  -> IO [(Int, [((Context, Word), Occurrences)])]
mapPartitionIndex _ _ _ ls = return [(1,ls)]

{-
class (Ord k2) => MapReducible mr k2 v2 | mr -> k2, mr -> v2 where
  mergeMR  :: mr -> mr -> IO mr
  reduceMR :: mr -> k2 -> [v2] -> IO (Maybe (mr)) 

mergeMR i1 i2       = return $ mergeIndexes i1 i2 
-}
{-
mergeIndex
  :: ActionEnvironment -> ()
  -> [((Context, Word), Occurrences)] -> IO [((Context, Word), [Occurrences])]
mergeIndex =
-}

reduceOccurrences 
  :: ActionEnvironment -> ()
  -> (Context, Word) -> [Occurrences]
  -> IO (Maybe Occurrences)
reduceOccurrences _ _ _ os
 = do
   let os' = (IM.unionsWith IS.union os)
   return $ Just $ os'


reducePartitionOccurrences
  :: ActionEnvironment -> ()
  -> Int -> [((Context, Word),Occurrences)] -> IO [(Int, [((Context, Word),Occurrences)])]
reducePartitionOccurrences _ _ _ ls = return [(1,ls)]



indexerBuildIndexAction
  :: ActionConfiguration 
       ()                                -- state
       () ((Context, Word),Occurrences)  -- k1, v1
       () ((Context, Word),Occurrences)  -- k2, v2
       ((Context, Word),Occurrences)     -- v3 == v2
       Inverted                          -- v4
indexerBuildIndexAction
  = -- readActionConfiguration $
      (defaultActionConfiguration "INDEX_BUILD")
        { ac_Map     = Just mapAction
        , ac_Combine = Nothing
        , ac_Reduce  = Just reduceAction
        }
    where
      mapAction 
        = (defaultMapConfiguration (mapBuildIndex))
            { mc_Partition = mapPartitionBuildIndex }
      reduceAction
        = (defaultReduceConfiguration (reduceBuildIndex))
            {{- rc_Merge     = mergeIndex -} 
             rc_Partition = reducePartitionBuildIndex }

mapBuildIndex 
  :: ActionEnvironment -> ()
  -> () -> ((Context, Word), Occurrences)
  -> IO [((),((Context, Word), Occurrences))]
mapBuildIndex _ _ k v = return [(k,v)]

mapPartitionBuildIndex
  :: ActionEnvironment -> ()
  -> Int -> [((),((Context, Word), Occurrences))]
  -> IO [(Int, [((),((Context, Word), Occurrences))])]
mapPartitionBuildIndex _ _ _ ls = return [(1,ls)]

reduceBuildIndex 
  :: ActionEnvironment -> ()
  -> () -> [((Context, Word),Occurrences)]
  -> IO (Maybe Inverted)
reduceBuildIndex _ _ _ os
  = do
    let i   = emptyInverted
    let idx = foldl (\i' ((c,w),o) -> insertOccurrences c w o i') i os
        _   = rnf idx
    return $ Just $ idx 



reducePartitionBuildIndex
  :: ActionEnvironment -> ()
  -> Int -> [((),Inverted)] -> IO [(Int, [((),Inverted)])]
reducePartitionBuildIndex _ _ _ ls = return [(1,ls)]

-- -----------------------------------------------------------------------------
{-
encodeInputList :: (Binary k, Binary v) => [(k,v)] -> [FunctionData]
encodeInputList ls = map (\t -> TupleFunctionData (encode t)) ls

decodeOccurrencesList :: [FunctionData] -> [((Context, Word),Occurrences)]
decodeOccurrencesList ls = map (\(TupleFunctionData t) -> decode t) ls

decodeIndexList :: [FunctionData] -> [((),Inverted)]
decodeIndexList ls = map (\(TupleFunctionData t) -> decode t) ls
-}
{-
decodeResult :: JobResult -> Inverted
decodeResult (JobResult []) = error "no index found"
decodeResult (JobResult r) = decodeFunctionData $ head r
  where
  decodeFunctionData (TupleFunctionData b) = decode b
  decodeFunctionData _ = error "no index found" 
-}

buildIndex :: (HolDocuments d a, {- HolIndex i -} MapReduce mr {-, HolCache c -}) 
           => MRCrawlerConfig d a
           --   Int                -- ^ Number of parallel threads for MapReduce
           --   Int                -- ^ TraceLevel for Arrows
           -> d a                -- ^ List of input Data
           -- -> IndexerConfig      -- ^ Configuration for the Indexing process
           -- -> Inverted           -- ^ An empty HolIndex. This is used to determine which kind of index to use.
           -> mr
           -> IO [Inverted]        -- ^ returns a HolIndex
buildIndex config {- workerThreads traceLevel -} docs {- idxConfig emptyIndex -} mr
  = do
    let docs' =  (map (\(i,d) -> (i, uri d)) (IM.toList $ toMap docs))
    
    {-
    let ji = JobInfo
             "indexer-job"
             (encode ())
             (Just "INDEX_OCCURRENCES")
             (Nothing)
             (Just "INDEX_OCCURRENCES")
             (Just TOTFile)
             (Nothing)
             (Just TOTRawTuple)
             1
             1
             1
             (encodeInputList docs')
    -}   
    runX (traceMsg 0 (" run indexer phase 1: "))
                     
    (res,_) <- doMapReduce (indexerOccurrencesAction config)
         ()
         docs'
         []
         1
         5
         1
         1
         TOTRawTuple
         mr 
       
    runX (traceMsg 0 (" result of phase 1: "))       
    
    runX (traceMsg 0 (" num of tuples: "))
    runX (traceMsg 0 (show $ length res))

    let os' = map (\t -> ((),t)) res
{-
    let ji2 = JobInfo
             "indexer-job"
             (encode ())
             (Just "INDEX_BUILD")
             (Nothing)
             (Just "INDEX_BUILD")
             (Just TOTFile)
             (Nothing)
             (Just TOTRawTuple)
             1
             1
             1
             (encodeInputList os')
-}    
    runX (traceMsg 0 (" run indexer phase 2: "))
                      
    (res',_) <- doMapReduce
       (indexerBuildIndexAction)
       ()
       os'
       []
       1
       1
       1
       1
       TOTRawTuple
       mr
    
    runX (traceMsg 0 (" result of the indexer: "))       
    
    runX (traceMsg 0 (" num of indexes: "))
    runX (traceMsg 0 (show $ length res'))
    
    let idx = map (snd) res'
    
    return idx
{-  = let docs' =  (map (\(i,d) -> (i, uri d)) (IM.toList $ toMap docs)) in
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

                    )
                    docs'
                 )
-}
{-
buildIndexM :: (HolDocuments d a, HolIndexM m i, HolCache c) => 
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
-}


-- | The MAP function in a MapReduce computation for building indexes.
--   The first three parameters have to be passed to the function to receive
--   a function with a valid MapReduce-map signature.
--
--   The function optionally outputs some debug information and then starts
--   the processing of a file by passing it together with the configuration
--   for different contexts to the @processDocument@ function where the file
--   is read and then the interesting parts configured in the
--   context configurations are extracted.

computeOccurrences :: -- HolCache c =>
               Int -> FS.FileSystem -> Bool -> [ContextConfig] -> Attributes -- -> Maybe c  
            -> DocId -> String -> IO [((Context, Word), Occurrences)]
computeOccurrences traceLevel fileSystem fromTmp contextConfigs attrs {- cache -} docId theUri
    = do
      clt <- getClockTime
      cat <- toCalendarTime clt
      res <- runX (     setTraceLevel traceLevel
                    >>> traceMsg 1 ((calendarTimeToString cat) ++ " - indexing document: " 
                                                               ++ show docId ++ " -> "
                                                               ++ show theUri)
                    >>> processDocument traceLevel fileSystem attrs' contextConfigs {- cache -} docId theUri
--                    >>> arr (\ (c, w, d, p) -> (c, (w, d, p)))
                    >>> strictA
             )
      return $ buildPositions res 
    where
    attrs' = if fromTmp then addEntries standardReadTmpDocumentAttributes attrs else attrs
    buildPositions :: [(Context, Word, DocId, Position)] -> [((Context, Word),  Occurrences)]
    buildPositions l = M.foldWithKey (\(c,w,d) ps acc -> ((c,w),IM.singleton d ps) : acc) [] $
      foldl (\m (c,w,d,p) -> M.insertWith IS.union (c,w,d) (IS.singleton p) m) M.empty l 
                             

-- -----------------------------------------------------------------------------
    
-- | Downloads a document and calls the function to process the data for the
--   different contexts of the index
processDocument :: -- HolCache c =>  
     Int
  -> FS.FileSystem
  -> Attributes
  -> [ContextConfig]
--  -> Maybe c
  -> DocId 
  -> URI
  -> IOSLA (XIOState s) b (Context, Word, DocId, Position)
processDocument traceLevel fileSystem attrs ccs {- cache -} docId theUri =
        withTraceLevel (traceLevel - traceOffset) 
        -- (readDocument attrs theUri)        
        (arrIO (\_ ->  do
          c <- FS.getFileContent theUri fileSystem
          case c of
            (Just cs)   -> return $ decode cs
            (Nothing) -> return "" -- TODO mark error here
          )
        )        
    >>> (readFromString attrs)
    >>> (catA $ map (processContext {- cache -} docId) ccs )   -- process all context configurations  
    


-- | Process a Context. Applies the given context configuration to extract information from
--   the XmlTree that is passed in the arrow.
processContext :: 
--  ( HolCache c) => 
--     Maybe c
     DocId
  -> ContextConfig
  -> IOSLA (XIOState s) XmlTree (Context, Word, DocId, Position)

processContext {-cache-} docId cc
    = cc_preFilter cc                                         -- convert XmlTree
      >>>
      fromLA extractWords
      >>>
{-      ( if ( isJust cache
       &&
       cc_addToCache cc
     )
  then perform (arrIO storeInCache)
  else this
      )
      >>>
-}    arrL genWordList
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
{-
    storeInCache s
      = let t = unwords s in 
            if t /= "" then putDocText (fromJust cache) (cc_name cc) docId t
                       else return()
-}

getTexts  :: LA XmlTree XmlTree
getTexts                                                      -- select all text nodes
    =  choiceA
       [ isElem :-> ( space                                   -- substitute tags by a single space
          <+>                                     -- so tags act as word delimiter
          (getChildren >>> getTexts)
          <+>
          space
        )                                       -- tags are interpreted as word delimiter
       , isText :-> this              -- take the text nodes
       , this   :-> none              -- ignore anything else
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