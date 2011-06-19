{-# OPTIONS #-}

-- ------------------------------------------------------------

module W3W.PageInfo
    ( PageInfo(..)
    , mkPageInfo
    , w3wGetTitle
    , w3wGetPageInfo
    )

where
import           	Control.DeepSeq
import 		 		    Control.Monad			( liftM4 )
import           	Data.Binary                    ( Binary(..) )
import qualified 	Data.Binary                    as B
import           	Data.List                      ( isPrefixOf )
import		 		    Holumbus.Crawler
import		 		    Text.XML.HXT.Core
import           	W3W.Extract
import	          W3W.Date as D
import        		Text.Regex.XMLSchema.String (tokenizeExt)
import        		Text.JSON


-- ------------------------------------------------------------

-- | Additional information about a function.

data PageInfo = PageInfo 
    		  	{ modified 	:: String      		-- ^ The last modified timestamp
			      , author 	:: String       	-- ^ The author
            , content   :: String           -- ^ The first few lines of the page contents
            , dates     :: String           -- ^ The dates
			      } 
			      deriving (Show, Eq)

mkPageInfo 			:: String -> String -> String -> String -> PageInfo
mkPageInfo			= PageInfo

instance XmlPickler PageInfo where
    xpickle 			= xpWrap (fromTuple, toTuple) xpFunction
	where
	fromTuple (m, a, c, d)
			 	= PageInfo m a c d
	toTuple (PageInfo m a c d)
				= (m, a, c, d)

	xpFunction		= xp4Tuple xpModified xpAuthor xpContent xpDates
	    where 							-- We are inside a doc-element, and everything is stored as attribute.
	    xpModified 		= xpAttr "modified" xpText0
	    xpAuthor     	= xpAttr "author"   xpText0
	    xpContent 		= xpAttr "content"  xpText0
	    xpDates 	  	= xpAttr "dates"    xpText0

instance NFData PageInfo where
    rnf (PageInfo m a c d)	= rnf m `seq` rnf a `seq` rnf c `seq` rnf d `seq` ()

instance B.Binary PageInfo where
    put (PageInfo m a c d)
			 	= put m >> put a >> put c >> put d
    get 		= do
				  r <- liftM4 PageInfo get get get get
				  rnf r `seq` return r

-- ------------------------------------------------------------
--
-- the arrows for building the document descr
--
-- ------------------------------------------------------------

w3wGetTitle                     :: IOSArrow XmlTree String
w3wGetTitle                     = fromLA $
                                  ( getHtmlTitle		-- title contents
                                    >>>
                                    isA (not . null)    -- if empty, take the URI as title
                                  )
                                  `orElse`
                                  getURI

w3wGetPageInfo                  :: D.DateExtractorFunc -> IOSArrow XmlTree PageInfo
w3wGetPageInfo dateExtractor   = ( fromLA (getModified `withDefault` "")
                                    &&&
                                    fromLA (getAuthor `withDefault` "")
                                    &&&
                                    getPageCont
									                  &&& 
									                  (getTeaserTextDates dateExtractor)
                                  )
                                  >>^
                                  (\ (m, (a, (c, d))) -> mkPageInfo m a c d)

getModified                     :: LA XmlTree String
getModified                     = ( getAttrValue0 "http-last-modified"		-- HTTP header
                                    `orElse`
                                    ( getMetaAttr "date" >>> isA (not . null) ) -- meta tag date (typo3)
                                    `orElse`
                                    getAttrValue0 "http-date"                    -- HTTP server time and date
                                  )
                                  >>^
                                  normalizeDateModified

getAuthor                       :: LA XmlTree String
getAuthor                       = getAuthorFromURI
                                  `orElse`
                                  getAuthorFromContent
    where
    getAuthorFromURI		= single
                                  ( getURI
                                    >>>
                                    arrL uri2Words
                                    >>>
                                    isA ("~" `isPrefixOf`)
                                    >>>
                                    arr short2Name
                                    >>>
                                    isA (not . null)
                                  )
    getAuthorFromContent        = none		-- not yet implemented


getPageCont :: IOSArrow XmlTree String
getPageCont = getHtmlText
              >>^
              (words >>> unwordsCont 50)	-- take the first 50 words from content

getTeaserTextDates :: D.DateExtractorFunc -> IOSArrow XmlTree String
getTeaserTextDates dateExtractor = getHtmlPlainText
	                 >>^
                   (words >>> unwords >>> (D.dateRep2DatesContext . dateExtractor) >>> toJSONArray)

toJSONArray :: [String] -> String
toJSONArray strings = encodeStrict $ showJSONs strings

-- ------------------------------------------------------------

