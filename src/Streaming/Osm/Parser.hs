{-# LANGUAGE OverloadedStrings #-}

module Streaming.Osm.Parser where

import           Control.Applicative ((<|>), optional)
import qualified Data.Attoparsec.ByteString as A
import           Data.Bits
import qualified Data.ByteString as B
import           Streaming.Osm.Types
import           Streaming.Osm.Util

---

-- | Parse a `BlobHeader`.
header :: A.Parser BlobHeader
header = do
  A.take 4
  A.word8 0x0a
  A.anyWord8
  t <- A.string "OSMHeader" <|> A.string "OSMData"
  i <- optional (A.word8 0x12 *> varint >>= A.take)
  d <- A.word8 0x18 *> varint
  pure $ BlobHeader t i d

-- | Parse some Varint, which may be made up of multiple bytes.
varint :: (Num a, Bits a) => A.Parser a
varint = foldBytes' <$> A.takeWhile (\b -> testBit b 7) <*> A.anyWord8
{-# INLINABLE varint #-}
