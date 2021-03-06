{-# OPTIONS #-}

-- ------------------------------------------------------------
-- |
-- A test crawler:
-- Crawls a collection of documents and extracts the text from the documents.
-- Result is a map from URIs to a string of words found in the 

module WWWCheck.URIChecker
where

import           Control.DeepSeq

import           Data.Binary                    ( Binary )
import qualified Data.Binary                    as B                    -- else naming conflict with put and get from Monad.State

import           Data.Function.Selector

import qualified Data.Map                       as M

import           Holumbus.Crawler

import           Text.XML.HXT.Core              hiding          ( when
                                                                , getState
                                                                )
import qualified Text.XML.HXT.Core              as X

-- ------------------------------------------------------------

data URIClass           = Contents | Exists | Not200OK | Manual | Ignore | Illegal
                          deriving (Eq, Show, Enum)

data DocDescr           = DD { dd_class         :: ! URIClass
                             , dd_status        :: ! String
                             , dd_message       :: ! String
                             , dd_mimetype      :: ! String
                             , dd_modified      :: ! String
                             , dd_uris          :: ! URIs
                             }
                          deriving (Show)

type DocMap             = M.Map URI DocDescr

type URICrawlerConfig   = CrawlerConfig DocDescr DocMap

type URIClassList       = [(String, URIClass)]

type URIClassifier      = URI -> URIClass

type URICrawlerAction x = CrawlerAction DocDescr DocMap x

-- ------------------------------------------------------------

instance NFData URIClass where
    rnf x               = x `seq` ()

instance Binary URIClass where
    put s               = B.put (fromEnum s)
    get                 = do
                          i <- B.get
                          return (toEnum i)
instance NFData DocDescr where
    rnf (DD x1 x2 x3 x4 x5 x6)
                        = rnf x1 `seq` rnf x2 `seq` rnf x3 `seq` rnf x4 `seq` rnf x5 `seq` rnf x6

instance Binary DocDescr where
    put dd              = do
                          B.put $ dd_class    dd
                          B.put $ dd_status   dd
                          B.put $ dd_message  dd
                          B.put $ dd_mimetype dd
                          B.put $ dd_modified dd
                          B.put $ dd_uris     dd
    get                 = do
                          c <- B.get
                          s <- B.get
                          e <- B.get
                          m <- B.get
                          o <- B.get
                          u <- B.get
                          return $ DD { dd_class        = c
                                      , dd_status       = s
                                      , dd_message      = e
                                      , dd_mimetype     = m
                                      , dd_modified     = o
                                      , dd_uris         = u
                                      }

-- ------------------------------------------------------------

invalidDocDescr         :: DocDescr
invalidDocDescr         = DD { dd_class         = Illegal
                             , dd_status        = "999"
                             , dd_message       = "not there"
                             , dd_mimetype      = "none/none"
                             , dd_modified      = "???"
                             , dd_uris          = emptyURIs
                             }

simpleURIClassifier                     :: URIClassList -> URIClassifier
simpleURIClassifier []             _    = Illegal
simpleURIClassifier ((re, c) : us) uri
    | match re uri                      = c
    | otherwise                         = simpleURIClassifier us uri

emptyDocMap                             :: DocMap
emptyDocMap                             = M.empty

uriCrawlerConfig                        :: String -> SysConfig -> URIClassifier -> URICrawlerConfig
uriCrawlerConfig agent config ucf       = setS theSysConfig config
                                          >>>
                                          setS theCrawlerName agent
                                          >>>
                                          setS thePreRefsFilter remContents                     -- throw away content when URL class  isn't Contents
                                          >>>
                                          setS theProcessRefs   ( getHtmlReferences             -- collect all a href
                                                                  <+>
                                                                  getDocReferences              -- all other href, src, ...
                                                                  <+>
                                                                  getLocationReference          -- redirect location in case of a 301 or 302 response
                                                                )
                                          >>>
                                          setS theFollowRef     followRefs
                                          >>>
                                          setS thePreDocFilter  remContents                     -- throw away content when URL class  isn't Contents
                                          >>>
                                          setS theProcessDoc    (rnfA mkDocDescr)               -- force complete evaluation of result of document contens
                                          $
                                          baseConfig
    where
    baseConfig                          = defaultHtmlCrawlerConfig insertDocDescr mergeDescr    -- take the default HTML crawler config
                                                                                                -- and set the accumulator ops

    mergeDescr                          :: MergeDocResults DocMap
    mergeDescr dm1 dm2
        | M.size dm1 < M.size dm2       = mergeDescr dm2 dm1
        | otherwise                     = return $ M.union dm1 dm2

    insertDocDescr                      :: AccumulateDocResult DocDescr DocMap
    insertDocDescr x                    = return . insertDoc x                                  -- TODO: urls not to be checked must be added into document map

    insertDoc (uri, dd) dm              = M.insert uri dd dm1
                                          where
                                          dm1 = foldURIs addUri dm (dd_uris dd)
                                          addUri uri' dm'
                                              | contOrEx uc'            = dm'                   -- filter uris to be accessed
                                              | uri' `M.member` dm'     = dm'                   -- filter already known uris
                                              | otherwise               = M.insert uri' dd' dm'
                                              where
                                              uc' = ucf uri'
                                              dd' = DD { dd_class       = uc'
                                                       , dd_status      = "999"
                                                       , dd_message     = ms uc'
                                                       , dd_mimetype    = ""
                                                       , dd_modified    = ""
                                                       , dd_uris        = emptyURIs
                                                       }
                                              ms Manual         = "Manual Check"
                                              ms Illegal        = "Illegal URI"
                                              ms Ignore         = "Ignored URI"
                                              ms c              = show c

    followRefs                          = contOrEx . ucf                                        -- these urls must be accessed
    contOrEx                            = (`elem` [Contents, Exists])

    remContents                         = replaceChildren none                                  -- throw away document content when URL class is no Contents
                                          `X.when`
                                          (ucfA >>> isA (/= Contents))

    ucfA                                =  getAttrValue transferURI >>^ ucf

    mkDocDescr                          :: IOSArrow XmlTree DocDescr
    mkDocDescr                          = ( ucfA
                                            &&&
                                            getAttrValue transferStatus
                                            &&&
                                            getAttrValue transferMessage
                                            &&&
                                            getAttrValue transferMimeType
                                            &&&
                                            getAttrValue http_last_modified
                                            &&&
                                            ( listA ( getHtmlReferences
                                                      <+>
                                                      getDocReferences
                                                      <+>
                                                      getLocationReference                      -- redirect location in case of a 301 or 302 response
                                                    )
                                              >>^ fromListURIs
                                            )
                                          )
                                          >>^
                                          ( \ (x1, (x2, (x3, (x4, (x5, x6))))) -> DD { dd_class    = if contOrEx x1 && x2 /= "200"
                                                                                                     then Not200OK
                                                                                                     else x1
                                                                                     , dd_status   = x2
                                                                                     , dd_message  = x3
                                                                                     , dd_mimetype = x4
                                                                                     , dd_modified = x5
                                                                                     , dd_uris     = x6
                                                                                     }
                                          )
                                            

uriCrawlerInitState     :: CrawlerState DocMap
uriCrawlerInitState     = initCrawlerState emptyDocMap

-- ------------------------------------------------------------

stdURIChecker           :: (Int, Int, Int)
                        -> (Int, String)
                        -> (Priority, Priority)
                        -> String
                        -> SysConfig
                        -> Maybe String
                        -> URI
                        -> URIClassList -> IO DocMap

stdURIChecker (maxDocs, maxParDocs, maxParThreads)
              (saveIntervall, savePath)
              (trc, trcx)
              agent
              sysConfig
              resumeLoc
              startUri
              uriClasses
                        = do
                          (_, dm) <- runCrawler action config uriCrawlerInitState
                          return (getS theResultAccu dm)
    where
    action              = maybe (crawlDocs [startUri]) crawlerResume $ resumeLoc
    config              = setCrawlerMaxDocs maxDocs maxParDocs maxParThreads
                          >>>
                          setCrawlerSaveConf saveIntervall savePath
                          >>>
                          setCrawlerTraceLevel trc trcx
                          >>>
                          enableRobotsTxt                       -- change to disableRobotsTxt, when robots.txt becomes boring
                          $
                          uriCrawlerConfig agent sysConfig (simpleURIClassifier ((startUri, Contents) : uriClasses))

-- ------------------------------------------------------------
