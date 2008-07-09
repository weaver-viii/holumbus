-- ----------------------------------------------------------------------------

{- |
  Module     : Holumbus.Query.Processor
  Copyright  : Copyright (C) 2007, 2008 Timo B. Huebel
  License    : MIT

  Maintainer : Timo B. Huebel (tbh@holumbus.org)
  Stability  : experimental
  Portability: portable
  Version    : 0.3

  The Holumbus query processor. Supports exact word or phrase queries as well
  as fuzzy word and case-insensitive word and phrase queries. Boolean
  operators like AND, OR and NOT are supported. Context specifiers and
  priorities are supported, too.

-}

-- ----------------------------------------------------------------------------

{-# OPTIONS -farrows #-}

module Holumbus.Query.Processor 
  (
  -- * Processor types
  ProcessConfig (..)
  
  -- * Processing
  , processQuery
  , processPartial
  )
where

import Data.Maybe
import Data.Binary (Binary (..))
import Data.Function

import Control.Monad
import Control.Parallel.Strategies

import qualified Data.List as L
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS

import Holumbus.Index.Common hiding (contexts)
import qualified Holumbus.Index.Common as IDX

import Holumbus.Query.Language.Grammar

import Holumbus.Query.Fuzzy (FuzzyScore, FuzzyConfig)
import qualified Holumbus.Query.Fuzzy as F

import Holumbus.Query.Result (Result)
import qualified Holumbus.Query.Result as R

import Holumbus.Query.Intermediate (Intermediate)
import qualified Holumbus.Query.Intermediate as I

-- | The configuration for the query processor.
data ProcessConfig  = ProcessConfig 
  { fuzzyConfig   :: !FuzzyConfig -- ^ The configuration for fuzzy queries.
  , optimizeQuery :: !Bool        -- ^ Optimize the query before processing.
  , wordLimit     :: !Int         -- ^ The maximum number of words used from a prefix. Zero switches off limiting.
  }

instance Binary ProcessConfig where
  put (ProcessConfig fc o l) = put fc >> put o >> put l
  get = liftM3 ProcessConfig get get get

-- | The internal state of the query processor.
data ProcessState i = ProcessState 
  { config   :: !ProcessConfig   -- ^ The configuration for the query processor.
  , contexts :: ![Context]       -- ^ The current list of contexts.
  , index    :: !i               -- ^ The index to search.
  , total    :: !Int             -- ^ The number of documents in the index.
  }

-- | Get the fuzzy config out of the process state.
getFuzzyConfig :: HolIndex i => ProcessState i -> FuzzyConfig
getFuzzyConfig = fuzzyConfig . config

-- | Set the current context in the state.
setContexts :: HolIndex i => [Context] -> ProcessState i -> ProcessState i
setContexts cs (ProcessState cfg _ i t) = ProcessState cfg cs i t

-- | Initialize the state of the processor.
initState :: HolIndex i => ProcessConfig -> i -> Int -> ProcessState i
initState cfg i t = ProcessState cfg (IDX.contexts i) i t

-- | Try to evaluate the query for all contexts in parallel.
forAllContexts :: (Context -> Intermediate) -> [Context] -> Intermediate
forAllContexts f cs = L.foldl' I.union I.emptyIntermediate $ parMap rnf f cs

-- | Just everything.
allDocuments :: HolIndex i => ProcessState i -> Intermediate
allDocuments s = forAllContexts (\c -> I.fromList "" c $ IDX.allWords (index s) c) (contexts s)

-- | Process a query only partially in terms of a distributed index. Only the intermediate 
-- result will be returned.
processPartial :: (HolIndex i) => ProcessConfig -> i -> Int -> Query -> Intermediate
processPartial cfg i t q = process (initState cfg i t) oq
  where
  oq = if optimizeQuery cfg then optimize q else q

-- | Process a query on a specific index with regard to the configuration.
processQuery :: (HolIndex i, HolDocuments d c) => ProcessConfig -> i -> d c -> Query -> Result c
processQuery cfg i d q = I.toResult d (process (initState cfg i (sizeDocs d)) oq)
  where
  oq = if optimizeQuery cfg then optimize q else q

-- | Continue processing a query by deciding what to do depending on the current query element.
process :: HolIndex i => ProcessState i -> Query -> Intermediate
process s (Word w)           = processWord s w
process s (Phrase w)         = processPhrase s w
process s (CaseWord w)       = processCaseWord s w
process s (CasePhrase w)     = processCasePhrase s w
process s (FuzzyWord w)      = processFuzzyWord s w
process s (Negation q)       = processNegation s (process s q)
process s (BinQuery o q1 q2) = processBin s o (process s q1) (process s q2)
process s (Specifier c q)   = process (setContexts c s) q

-- | Process a single, case-insensitive word by finding all documents which contain the word as prefix.
processWord :: HolIndex i => ProcessState i -> String -> Intermediate
processWord s q = forAllContexts wordNoCase (contexts s)
  where
  wordNoCase c = I.fromList q c $ limitWords s $ IDX.prefixNoCase (index s) c q

-- | Process a single, case-sensitive word by finding all documents which contain the word as prefix.
processCaseWord :: HolIndex i => ProcessState i -> String -> Intermediate
processCaseWord s q = forAllContexts wordCase (contexts s)
  where
  wordCase c = I.fromList q c $ limitWords s $ IDX.prefixCase (index s) c q

-- | Process a phrase case-insensitive.
processPhrase :: HolIndex i => ProcessState i -> String -> Intermediate
processPhrase s q = forAllContexts phraseNoCase (contexts s)
  where
  phraseNoCase c = processPhraseInternal (IDX.lookupNoCase (index s) c) c q

-- | Process a phrase case-sensitive.
processCasePhrase :: HolIndex i => ProcessState i -> String -> Intermediate
processCasePhrase s q = forAllContexts phraseCase (contexts s)
  where
  phraseCase c = processPhraseInternal (IDX.lookupCase (index s) c) c q

-- | Process a phrase query by searching for every word of the phrase and comparing their positions.
processPhraseInternal :: (String -> RawResult) -> Context -> String -> Intermediate
processPhraseInternal f c q = let
  w = words q 
  m = mergeOccurrencesList $ map snd $ f (head w) in
  if m == IM.empty then I.emptyIntermediate
  else I.fromList q c [(q, processPhrase' (tail w) 1 m)]
  where
  processPhrase' :: [String] -> Int -> Occurrences -> Occurrences
  processPhrase' [] _ o = o
  processPhrase' (x:xs) p o = processPhrase' xs (p+1) (IM.filterWithKey (nextWord $ map snd $ f x) o)
    where
    nextWord :: [Occurrences] -> Int -> Positions -> Bool
    nextWord [] _ _  = False
    nextWord no d np = maybe False hasSuccessor (IM.lookup d (mergeOccurrencesList no))
      where
      hasSuccessor :: Positions -> Bool
      hasSuccessor w = IS.fold (\cp r -> r || (IS.member (cp + p) w)) False np

-- | Process a single word and try some fuzzy alternatives if nothing was found.
processFuzzyWord :: HolIndex i => ProcessState i -> String -> Intermediate
processFuzzyWord s oq = processFuzzyWord' (F.toList $ F.fuzz (getFuzzyConfig s) oq) (processWord s oq)
  where
  processFuzzyWord' :: [(String, FuzzyScore)] -> Intermediate -> Intermediate
  processFuzzyWord' []     r = r
  processFuzzyWord' (q:qs) r = if I.null r then processFuzzyWord' qs (processWord s (fst q)) else r

-- | Process a negation by getting all documents and substracting the result of the negated query.
processNegation :: HolIndex i => ProcessState i -> Intermediate -> Intermediate
processNegation s r = I.difference (allDocuments s) r

-- | Process a binary operator by caculating the union or the intersection of the two subqueries.
processBin :: HolIndex i => ProcessState i -> BinOp -> Intermediate -> Intermediate -> Intermediate
processBin _ And r1 r2 = I.intersection r1 r2
processBin _ Or r1 r2  = I.union r1 r2
processBin _ But r1 r2 = I.difference r1 r2

-- | Limit a 'RawResult' to a fixed amount of the best words. A simple heuristic is used to 
-- determine the quality of a word: The total number of occurrences divided by the number of 
-- documents in which the word appears. 
limitWords :: HolIndex i => ProcessState i -> RawResult -> RawResult
limitWords s r = if cut then map snd $ take limit $ L.sortBy (compare `on` fst) $ map calcScore r else r
  where
  limit = wordLimit $ config s
  cut = limit > 0 && length r > limit
  calcScore :: (Word, Occurrences) -> (Double, (Word, Occurrences))
  calcScore w@(_, o) = (log (fromIntegral (total s) / fromIntegral (IM.size o)), w)

-- | Merge occurrences
mergeOccurrencesList :: [Occurrences] -> Occurrences
mergeOccurrencesList = IM.unionsWith IS.union