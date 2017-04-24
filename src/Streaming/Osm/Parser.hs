{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Streaming.Osm.Parser where

import           Codec.Compression.Zlib (decompress)
import           Control.Applicative ((<|>), optional)
import qualified Data.Attoparsec.ByteString as A
import           Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import           Data.Int
import qualified Data.Map as M
import qualified Data.Vector as V
import           Data.Word
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

blob :: A.Parser Blob
blob = Blob <$> A.eitherP dcmp comp
  where dcmp = A.word8 0x0a *> varint >>= A.take
        comp = (,) <$> (A.word8 0x10 *> varint) <*> (A.word8 0x1a *> varint >>= A.take)

-- This is likely not needed.
headerBlock :: A.Parser [B.ByteString]
headerBlock = do
  optional (A.word8 0x0a *> varint >>= A.take)
  res <- A.many' (A.word8 0x22 *> varint >>= A.take)
  A.many'  (A.word8 0x2a *> varint >>= A.take)                  -- optional_features
  optional (A.word8 0x82 *> A.word8 0x01 *> varint >>= A.take)  -- writingprogram
  optional (A.word8 0x8a *> A.word8 0x01 *> varint >>= A.take)  -- source
  optional (A.word8 0x80 *> A.word8 0x02 *> varint @Int64)      -- osmosis_replication_timestamp
  optional (A.word8 0x88 *> A.word8 0x02 *> varint @Int64)      -- osmosis_replication_sequence_number
  optional (A.word8 0x92 *> A.word8 0x02 *> varint >>= A.take)  -- osmosis_replication_bas_url
  pure res

-- TODO: many or many' ?

-- TODO: Handle DenseNodes
-- | Called a @PrimitiveBlock@ in the OSM literature.
block :: A.Parser Block
block = do
  st <- A.word8 0x0a *> varint @Int *> stringTable
  ns <- A.word8 0x12 *> varint @Int *> A.many' (node st)
  ws <- A.word8 0x12 *> varint @Int >>= A.take >> pure [] -- *> A.many' (way st)
  rs <- A.word8 0x12 *> varint @Int >>= A.take >> pure [] -- *> A.many' (relation st)
  gran <- (A.word8 0x88 *> A.word8 0x01 *> varint @Int64) <|> pure 100   -- granularity
  date <- (A.word8 0x90 *> A.word8 0x01 *> varint @Int32) <|> pure 1000  -- date_granularity
  lato <- (A.word8 0x98 *> A.word8 0x01 *> varint @Int64) <|> pure 0     -- lat_offset
  lono <- (A.word8 0xa0 *> A.word8 0x01 *> varint @Int64) <|> pure 0     -- lon_offset
  pure $ Block (map (\f -> f gran lato lono) ns) ws rs

-- | The String Table will never be empty, since all Elements have
-- non-geographic metadata (username, etc.) which contain Strings. The result
-- must be a `V.Vector`, since we need random access to its contents.
stringTable :: A.Parser (V.Vector B.ByteString)
stringTable = V.fromList <$> A.many1 (A.word8 0x0a *> varint >>= A.take)

-- | Parse a `Node`. Uses `V.unsafeIndex` to quickly retrieve its tag
-- Strings, assuming that the Node's key/value pairs will always index a legal
-- value in the given String Table.
node :: V.Vector B.ByteString -> A.Parser (Int64 -> Int64 -> Int64 -> Node)
node st = do
  A.word8 0x0a
  varint @Int
  i   <- unzig <$> (A.word8 0x08 *> varint @Word64)
  ks  <- (A.word8 0x12 *> varint @Int *> A.many1 varint) <|> pure []
  vs  <- (A.word8 0x1a *> varint @Int *> A.many1 varint) <|> pure []
  oi  <- optional (A.word8 0x22 *> infoP i st)
  lat <- unzig <$> (A.word8 0x40 *> varint @Word64)
  lon <- unzig <$> (A.word8 0x48 *> varint @Word64)
  let ts = M.fromList $ zip (map (V.unsafeIndex st) ks) (map (V.unsafeIndex st) vs)
  pure $ (\gran lato lono -> Node (offset lato gran lat) (offset lono gran lon) oi ts)

way :: V.Vector B.ByteString -> A.Parser Way
way st = undefined

relation :: V.Vector B.ByteString -> A.Parser Relation
relation st = undefined

infoP :: Int64 -> V.Vector B.ByteString -> A.Parser Info
infoP i st = Info
  <$> pure (fromIntegral i)
  <*> ((A.word8 0x08 *> varint) <|> pure (-1))
  <*> optional (A.word8 0x10 *> varint)
  <*> optional (A.word8 0x18 *> varint)
  <*> optional (A.word8 0x20 *> varint)
  <*> optional (V.unsafeIndex st <$> (A.word8 0x28 *> varint))
  <*> ((>>= booly) <$> optional (A.word8 0x30 *> varint @Word8))

-- | Parse some Varint, which may be made up of multiple bytes.
varint :: (Num a, Bits a) => A.Parser a
varint = foldBytes' <$> A.takeWhile (\b -> testBit b 7) <*> A.anyWord8
{-# INLINABLE varint #-}

-- | Restore truncated LatLng values to their true `Double` representation.
offset :: Int64 -> Int64 -> Int64 -> Double
offset off gran coord = 0.000000001 * fromIntegral (off + (gran * coord))

-- | Decode a Z-encoded Word64 into a 64-bit Int.
unzig :: Word64 -> Int64
unzig n = fromIntegral unzigged
  where unzigged = shift n (-1) `xor` negate (n .&. 1)

booly :: Word8 -> Maybe Bool
booly 0 = Just False
booly 1 = Just True
booly _ = Nothing

--test :: IO (Either String [B.ByteString])
test = do
  bytes <- B.readFile "diomede.osm.pbf"
  pure $ A.parseOnly (header *> blob *> header *> blob) bytes >>= f
    where f (Blob { bytes = Left bs }) = A.parseOnly block bs
          f (Blob { bytes = Right (_, bs) }) = A.parseOnly block . BL.toStrict . decompress $ BL.fromStrict bs