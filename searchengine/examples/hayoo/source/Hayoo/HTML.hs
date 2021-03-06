-- ----------------------------------------------------------------------------

{- |
  Module     : Hayoo.HTML
  Copyright  : Copyright (C) 2008 Timo B. Huebel
  License    : MIT

  Maintainer : Timo B. Huebel (tbh@holumbus.org)
  Stability  : experimental
  Portability: portable
  Version    : 0.1

  The conversion functions for generating the HTML code of an Hayoo!
  search result.
 
-}

-- ----------------------------------------------------------------------------

{-# OPTIONS -fglasgow-exts -fno-warn-type-defaults #-}

module Hayoo.HTML 
  ( PickleState (..)
  , xpStatusResult
  )
where

import Control.Monad

import Data.Function

import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.IntMap as IM
import qualified Data.ByteString.UTF8 as B

import System.IO.Unsafe

import Text.XML.HXT.Arrow

import Holumbus.Index.Common
import Holumbus.Index.Cache

import Holumbus.Query.Result

import Hayoo.Common

type Template = XmlTree

data PickleState = PickleState
  { psQuery    :: String
  , psStart    :: Int
  , psStatic   :: Bool
  , psCache    :: Cache
  , psTemplate :: Template
  }

staticRoot :: String
staticRoot = "hayoo.html"

-- | The combined pickler for the status response and the result.
xpStatusResult :: PickleState -> PU StatusResult
xpStatusResult ps = xpDivId "result" $ xpWrap (undefined, \(s, r, m, p) -> (s, (m, p), r)) $ xpTriple xpStatus xpAggregation (xpResultHtml ps)
  where
  xpAggregation = xpDivId "aggregation" $ xpPair (xpModules ps) (xpPackages ps) 

-- | The aggregated modules list.
xpModules :: PickleState -> PU [(String, Int)]
xpModules ps = xpDivId "modules" $ xpWrap (undefined, \l -> ("Top 15 Modules", take 15 l)) $ xpPair (xpElemClass "div" "headline" $ xpText) (xpList xpRootModule)
  where
  xpRootModule = xpElemClass "div" "rootModule" $ xpPair (xpRootModuleLink $ psQuery ps) (xpElemClass "span" "rootModuleCount" $ xpPrim)

xpRootModuleLink :: String -> PU String
xpRootModuleLink q = xpElemClass "a" "rootModuleName" $ xpDuplicate $ xpPair (xpDuplicate $ xpPair xpStaticLink xpReplace) xpText
  where
  xpReplace = xpAttr "onclick" $ xpPrepend "addToQuery('module:" $ xpAppend "'); return false;" $ xpEscape
  xpStaticLink = xpAttr "href" $ xpWrap (undefined, makeQueryString) $ xpText
  makeQueryString s = staticRoot ++ "?query=" ++ q ++ "%20module%3A" ++ s

-- | The aggregated package list.
xpPackages :: PickleState -> PU [(String, Int)]
xpPackages ps = xpDivId "packages" $ xpWrap (undefined, \l -> ("Top 15 Packages", take 15 l)) $ xpPair (xpElemClass "div" "headline" $ xpText) (xpList xpPackage)
  where
  xpPackage = xpElemClass "div" "package" $ xpPair (xpPackageLink $ psQuery ps) (xpElemClass "span" "packageCount" $ xpPrim)
 
xpPackageLink :: String -> PU String
xpPackageLink q = xpElemClass "a" "packageLink" $ xpDuplicate $ xpPair (xpDuplicate $ xpPair xpStaticLink xpReplace) xpText
  where
  xpReplace = xpAttr "onclick" $ xpPrepend "addToQuery('package:" $ xpAppend "'); return false;" $ xpEscape
  xpStaticLink = xpAttr "href" $ xpWrap (undefined, makeQueryString) $ xpText
  makeQueryString s = staticRoot ++ "?query=" ++ q ++ "%20package%3A" ++ s


-- | Enclose the status message in a <div> tag.
xpStatus :: PU String
xpStatus = xpDivId "status" xpText

-- | The HTML Result pickler. Extracts the maximum word score for proper scaling in the cloud.
xpResultHtml :: PickleState -> PU (Result FunctionInfo)
xpResultHtml s = xpWrap (\((_, wh), (_, dh)) -> Result dh wh, \r -> ((maxScoreWordHits r, wordHits r), (sizeDocHits r, docHits r))) 
                 (xpPair (xpWordHitsHtml s) (xpDocHitsHtml s))

-- | Wrapping something in a <div> element with id attribute.
xpDivId :: String -> PU a -> PU a
xpDivId i p = xpElem "div" (xpAddFixedAttr "id" i p)

-- | Wrapping something in a <div> element with class attribute.
xpElemClass :: String -> String -> PU a -> PU a
xpElemClass e c p = xpElem e (xpAddFixedAttr "class" c p)

-- | Set the class of the surrounding element.
xpClass :: String -> PU a -> PU a
xpClass c p = xpAddFixedAttr "class" c p

-- | Seth the id of the surrounding element.
xpId :: String -> PU a -> PU a
xpId i p = xpAddFixedAttr "id" i p

-- | Append some text after pickling something else.
xpAppend :: String -> PU a -> PU a
xpAppend t p = xpWrap (\(v, _) -> v, \v -> (v, t)) (xpPair p xpText)

-- | Prepend some text before pickling something else.
xpPrepend :: String -> PU a -> PU a
xpPrepend t p = xpWrap (\(_, v) -> v, \v -> (t, v)) (xpPair xpText p)

-- | The HTML pickler for the document hits. Will be sorted by score. Also generates the navigation.
xpDocHitsHtml :: PickleState -> PU (Int, DocHits FunctionInfo)
xpDocHitsHtml s = xpWrap (\(d, n) -> (n, d) ,\(n, d) -> (d, n)) (xpPair (xpDocs (psCache s)) (xpPager s (psStart s)))
  where
  xpDocs c = xpDivId "documents" $ xpElem "table" (xpWrap (IM.fromList, toListSorted) (xpList $ xpDocInfoHtml c))
  toListSorted = take pageLimit . drop (psStart s) . reverse . L.sortBy (compare `on` (docScore . fst . snd)) . IM.toList -- Sort by score

xpPager :: PickleState -> Int -> PU Int
xpPager ps s = xpWrap wrapper (xpOption $ xpDivId "pager" (xpWrap (\_ -> 0, makePager s pageLimit) (xpOption $ xpQueryPager ps)))
  where
  wrapper = (undefined, \v -> if v > 0 then Just v else Nothing)

xpDocInfoHtml :: HolCache c => c -> PU (DocId, (DocInfo FunctionInfo, DocContextHits))
xpDocInfoHtml c = xpWrap (undefined, docToHtml) (xpPair xpQualified xpAdditional)
  where
  docToHtml (_, (DocInfo (Document _ _ Nothing) _, _)) = error "Expecting custom information for document"
  docToHtml (i, (DocInfo (Document t u (Just (FunctionInfo m s p l))) r, _)) = 
    (((modLink u, B.toString m), (u, "Score: " ++ show r, t), B.toString s), ((pkgLink $ B.toString p, B.toString p), (getDesc i, liftM B.toString $ l)))
    where
    modLink = takeWhile ((/=) '#')
    pkgLink "gtk2hs" = "http://www.haskell.org/gtk2hs"
    pkgLink p' = "http://hackage.haskell.org/cgi-bin/hackage-scripts/package/" ++ p'
    getDesc = unsafePerformIO . getDocText c "description" 
  xpQualified = xpElemClass "tr" "function" $ xpTriple xpModule xpFunction xpSignature
    where
    xpModule = xpCell "module" $ xpLink "module" xpText (xpAppend "." $ xpText)
    xpFunction = xpCell "name" $ xpElemClass "a" "function" $ xpTriple (xpAttr "href" xpText) (xpAttr "title" xpText) xpText
    xpSignature = xpCell "signature" $ xpPrepend ":: " xpSigDecl
  xpAdditional = xpElemClass "tr" "details" $ xpPair xpPackage xpDescSrc
    where
    xpPackage = xpCell "package" $ xpLink "package" xpText xpText
    xpDescSrc = xpCell "description" $ xpAddFixedAttr "colspan" "2" $ xpElem "div" $ xpPair xpDescription xpSource
    xpDescription = xpWrap (undefined, limitDescription) $ xpPair xpUnfoldLink (xpElemClass "span" "description" xpText)
    xpUnfoldLink = xpElemClass "a" "toggleFold" $ xpAddFixedAttr "onclick" "toggleFold(this);" $ xpText
    xpSource = xpOption $ (xpElemClass "span" "source" $ xpElemClass "a" "source" $ xpAppend "Source" $ xpAttr "href" $ xpText)
    limitDescription = maybe ("+", "No description. ") (\d -> ("+", d))

xpLink :: String -> PU String -> PU String -> PU (String, String)
xpLink c pa pb = xpElemClass "a" c $ xpPair (xpAttr "href" pa) pb

data Signature = Signature String
               | Declaration String

xpSigDecl :: PU String
xpSigDecl = xpWrap (undefined, makeSignature) (xpAlt tag [xpSig, xpDecl])
  where
  xpSig = xpWrap (Signature, \(Signature s) -> s) xpText
  xpDecl = xpWrap (Declaration, \(Declaration s) -> s) (xpElemClass "span" "declaration" $ xpText)
  tag (Signature _) = 0
  tag (Declaration _) = 1
  makeSignature s'
      | s `elem` ["data", "type", "newtype", "class"]	= Declaration s
      | otherwise					= Signature (replace "->" " -> " s)
      where s	= stringTrim s'

xpCell :: String -> PU a -> PU a
xpCell c p = xpElem "td" $ xpClass c $ p

xpWordHitsHtml :: PickleState -> PU (Score, WordHits)
xpWordHitsHtml ps = xpDivId "words" $ xpElemClass "div" "cloud" $ xpWrap (fromListSorted, toListSorted) (xpList xpWordHitHtml)
  where
  fromListSorted _ = (0.0, M.empty)
  toListSorted (s, wh) = map (\a -> (s, a)) $ L.sortBy (compare `on` fst) $ M.toList wh -- Sort by word
  xpWordHitHtml = xpWrap (wordFromHtml, wordToHtml) (xpWordHtml)
    where
    wordToHtml (m, (w, (WordInfo ts s, _))) = ((head ts, w), ((s, m), w))
    wordFromHtml ((t, _), ((s, m), w)) = (m, (w, (WordInfo [t] s, M.empty)))
    xpWordHtml = xpAppend " " $ xpElemClass "a" "cloud" $ xpPair (xpCloudLink (psQuery ps) (psStart ps)) xpScore

xpCloudLink :: String -> Int -> PU (String, Word)
xpCloudLink q s = xpDuplicate $ xpPair xpStaticLink xpReplace
  where
  xpReplace = xpAttr "onclick" $ xpPair (xpPrepend "replaceInQuery('" $ xpAppend "','" xpEscape) (xpAppend "'); return false;" $ xpEscape)
  xpStaticLink = xpAttr "href" $ xpWrap (\v -> (v, v), makeQueryString) $ xpText
  makeQueryString (needle, subst) = staticRoot ++ "?query=" ++ (replace needle subst q) ++ "&start=" ++ (show s)

xpEscape :: PU String
xpEscape = xpWrap (unescape, escape) xpText
  where
  unescape = filter ((/=) '\\')
  escape [] = []
  escape (x:xs) = if x == '\'' then "\\'" ++ escape xs else x : (escape xs)

xpScore :: PU ((Score, Score), Word)
xpScore = xpElem "span" $ xpPair (xpAttr "class" $ xpWrap (scoreFromHtml, scoreToHtml) xpText) xpText
  where
  scoreToHtml (v, top) = "cloud" ++ (show $ round (weightScore 1 9 top v))
  scoreFromHtml _ = (0.0, 0.0)
  weightScore mi ma to v = ma - ((to - v) / to) * (ma - mi)

pageLimit :: Int
pageLimit = 10

data Pager = Pager 
  { prevPage  :: Maybe Int -- == last predPages
  , predPages :: [(Int, Int)]
  , currPage  :: Int
  , succPages :: [(Int, Int)]
  , nextPage  :: Maybe Int -- == head succPages
  }

xpQueryPager :: PickleState -> PU Pager
xpQueryPager ps = xpWrap convert (xp5Tuple (xpNav "previous" "<") xpPages xpCurrPage xpPages (xpNav "next" ">"))
    where
    convert = (\(pv, pd, c, sc, nt) -> Pager pv pd c sc nt, \(Pager pv pd c sc nt) -> (pv, pd, c, sc, nt))
    xpNav c s = xpOption $ xpDuplicate $ xpElem "a" $ xpClass c $ xpAppend s $ xpPair xpShowPage xpStaticLink
    xpCurrPage = xpElem "span" $ xpClass "current" $ xpPrim
    xpPages =
      xpList $ xpElem "a" $ xpClass "page" $ xpPair (xpDuplicate $ xpPair xpShowPage xpStaticLink) xpPrim
    xpShowPage = xpAttr "onclick" $ xpPrepend "showPage(" $ xpAppend "); return false;" $ xpPrim
    xpStaticLink = xpAttr "href" $ xpPrepend (staticRoot ++ "?query=" ++ (psQuery ps) ++ "&start=") $ xpPrim

-- Start element (counting from zero), elements per page, total number of elements.
makePager :: Int -> Int -> Int -> Maybe Pager
makePager s p n = if n > p then Just $ Pager pv (drop (length pd - 10) pd) (length pd + 1) (take 10 sc) nt else Nothing
  where
  pv = if s < p then Nothing else Just (s - p)
  nt = if s + p >= n then Nothing else Just (s + p)
  pd = map (\x -> (x, x `div` p + 1)) $ genPred s []
    where
    genPred rp tp = let np = rp - p in if np < 0 then tp else genPred np (np:tp)
  sc = map (\x -> (x, x `div` p + 1)) $ genSucc s []
    where
    genSucc rs ts = let ns = rs + p in if ns >= n then ts else genSucc ns (ts ++ [ns])

xpDuplicate :: PU (a, a) -> PU a
xpDuplicate = xpWrap (\(v, _) -> v, \v -> (v, v))

