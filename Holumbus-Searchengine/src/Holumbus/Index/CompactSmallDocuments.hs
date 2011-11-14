{-# OPTIONS -XFlexibleInstances -XMultiParamTypeClasses #-}

-- ----------------------------------------------------------------------------

{- |
  Module     : Holumbus.Index.CompactDocuments
  Copyright  : Copyright (C) 2007-2010 Sebastian M. Schlatt, Timo B. Huebel
  License    : MIT

  Maintainer : Uwe Schmidt (uwe@fh-wedel.de)
  Stability  : experimental
  Portability: MultiParamTypeClasses FlexibleInstances

  A simple version of Holumbus.Index.Documents.
  This implementation is only for reading a document table in the search part of an application.
  The mapping of URIs to DocIds is only required during index building, not when accessing the index.
  So this 2. mapping is removed in this implementation for saving space
-}

-- ----------------------------------------------------------------------------

module Holumbus.Index.CompactSmallDocuments 
(
  -- * Documents type
  SmallDocuments (..)

  -- * Construction
  , emptyDocuments
  , singleton

  -- * Conversion
  , docTable2smallDocTable
)
where

import           Control.DeepSeq

import           Data.Binary				( Binary )
import qualified Data.Binary            		as B

import           Holumbus.Index.Common
import qualified Holumbus.Index.CompactDocuments	as CD

import           Text.XML.HXT.Core

-- ----------------------------------------------------------------------------

-- | The table to store the document descriptions

newtype SmallDocuments a	= SmallDocuments
                                  { idToSmallDoc   :: CD.DocMap a -- ^ A mapping from a doc id
                                                                  --   to the document itself.
                                  }

-- ----------------------------------------------------------------------------

instance (Binary a, HolIndex i) => HolDocIndex SmallDocuments a i where
    unionDocIndex dt1 ix1 dt2 ix2
        | s1 < s2		= unionDocIndex dt2 ix2 dt1 ix1
        | otherwise		= (dt, ix)
        where
	  dt   			= unionDocs     dt1  dt2s
          ix   			= mergeIndexes  ix1  ix2s

          dt2s 			= editDocIds    add1 dt2
          ix2s 			= updateDocIds' add1 ix2

          add1 			= mkDocId . (+ (theDocId m1)) . theDocId
          m1	 		= maxKeyDocIdMap . toMap $ dt1

          s1			= sizeDocs dt1
          s2			= sizeDocs dt2

-- ----------------------------------------------------------------------------

instance Binary a => HolDocuments SmallDocuments a where
  sizeDocs 			= sizeDocIdMap . idToSmallDoc
  
  lookupById  d i 		= maybe (fail "") return
                                  . fmap CD.toDocument
                                  . lookupDocIdMap i
                                  . idToSmallDoc
                                  $ d

  makeEmpty _ 			= emptyDocuments

  lookupByURI	 		= error "Not yet implemented"
  mergeDocs	 		= error "Not yet implemented"
  unionDocs			= error "Not yet implemented"
  insertDoc	 		= error "Not yet implemented"
  updateDoc	 		= error "Not yet implemented"
  removeById	 		= error "Not yet implemented"
  updateDocuments		= error "Not yet implemented"
  filterDocuments 		= error "Not yet implemented"
  editDocIds			= error "Not yet implemented"

  fromMap 			= SmallDocuments . CD.toDocMap
  toMap 			= CD.fromDocMap . idToSmallDoc

-- ----------------------------------------------------------------------------

instance NFData a => 		NFData (SmallDocuments a)
    where
    rnf (SmallDocuments i2d)	= rnf i2d `seq` ()

-- ----------------------------------------------------------------------------

instance (Binary a, XmlPickler a) =>
				XmlPickler (SmallDocuments a)
    where
    xpickle 			= xpElem "documents" $
                                  xpWrap convertDoctable $
				  xpWrap (fromListDocIdMap, toListDocIdMap) $
				  xpList xpDocumentWithId
	where
	convertDoctable 	= ( SmallDocuments
				  , idToSmallDoc
                                  )
	xpDocumentWithId 	= xpElem "doc" $
				  xpPair (xpAttr "id" xpDocId) xpickle

-- ----------------------------------------------------------------------------

instance Binary a => 		Binary (SmallDocuments a)
    where
    put (SmallDocuments i2d) 	= B.put i2d
    get 			= do
                                  i2d <- B.get
                                  return $ SmallDocuments i2d

-- ------------------------------------------------------------

-- | Create an empty table.

emptyDocuments 			:: SmallDocuments a
emptyDocuments 			= SmallDocuments emptyDocIdMap

-- | Create a document table containing a single document.

singleton 			:: (Binary a) => Document a -> SmallDocuments a
singleton d 			= SmallDocuments (singletonDocIdMap firstDocId (CD.fromDocument d))

-- | Convert a Compact document table into a small compact document table.
-- Called at the end of building an index

docTable2smallDocTable		:: CD.Documents a -> SmallDocuments a
docTable2smallDocTable		=  SmallDocuments . CD.idToDoc

-- ------------------------------------------------------------
