{-# LANGUAGE OverloadedStrings #-}
module Network.Mail.Mime
    ( -- * Datatypes
      Boundary (..)
    , Mail (..)
    , emptyMail
    , Address (..)
    , Alternatives
    , Part (..)
    , Encoding (..)
      -- * Render a message
    , renderMail
    , renderMail'
      -- * Sending messages
    , sendmail
    , sendmailCustom
    , renderSendMail
    , renderSendMailCustom
      -- * High-level 'Mail' creation
    , simpleMail
      -- * Utilities
    , randomString
    , quotedPrintable
    ) where

import qualified Data.ByteString.Lazy as L
import Blaze.ByteString.Builder.Char.Utf8
import Blaze.ByteString.Builder
import Blaze.ByteString.Builder.Internal.Write (fromWriteList)
import Data.Monoid
import System.Random
import Control.Arrow
import System.Process
import System.IO
import System.Exit
import System.FilePath (takeFileName)
import qualified Data.ByteString.Base64 as Base64
import Control.Monad ((<=<), forM)
import Data.List (intersperse)
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Encoding as LT
import Data.ByteString.Char8 ()
import Data.Bits ((.&.), shiftR)
import Data.Char (isAscii)
import Data.Word (Word8)
import qualified Data.ByteString as S
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- | Generates a random sequence of alphanumerics of the given length.
randomString :: RandomGen d => Int -> d -> (String, d)
randomString len =
    first (map toChar) . sequence' (replicate len (randomR (0, 61)))
  where
    sequence' [] g = ([], g)
    sequence' (f:fs) g =
        let (f', g') = f g
            (fs', g'') = sequence' fs g'
         in (f' : fs', g'')
    toChar i
        | i < 26 = toEnum $ i + fromEnum 'A'
        | i < 52 = toEnum $ i + fromEnum 'a' - 26
        | otherwise = toEnum $ i + fromEnum '0' - 52

-- | MIME boundary between parts of a message.
newtype Boundary = Boundary { unBoundary :: Text }
instance Random Boundary where
    randomR = const random
    random = first (Boundary . T.pack) . randomString 10

-- | An entire mail message.
data Mail = Mail
    { mailFrom :: Address
    , mailTo   :: [Address]
    , mailCc   :: [Address]
    , mailBcc  :: [Address]
    -- | Other headers, excluding from, to, cc and bcc.
    , mailHeaders :: [(S.ByteString, Text)]
    -- | A list of different sets of alternatives. As a concrete example:
    --
    -- > mailParts = [ [textVersion, htmlVersion], [attachment1], [attachment1]]
    --
    -- Make sure when specifying alternatives to place the most preferred
    -- version last.
    , mailParts :: [Alternatives]
    }

-- | A mail message with the provided 'from' address and no other
-- fields filled in.
emptyMail :: Address -> Mail
emptyMail from = Mail
    { mailFrom    = from
    , mailTo      = []
    , mailCc      = []
    , mailBcc     = []
    , mailHeaders = []
    , mailParts   = []
    }

data Address = Address
    { addressName  :: Maybe Text
    , addressEmail :: Text
    }

-- | How to encode a single part. You should use 'Base64' for binary data.
data Encoding = None | Base64 | QuotedPrintableText | QuotedPrintableBinary

-- | Multiple alternative representations of the same data. For example, you
-- could provide a plain-text and HTML version of a message.
type Alternatives = [Part]

-- | A single part of a multipart message.
data Part = Part
    { partType :: Text -- ^ content type
    , partEncoding :: Encoding
    -- | The filename for this part, if it is to be sent with an attachemnt
    -- disposition.
    , partFilename :: Maybe Text
    , partHeaders :: Headers
    , partContent :: L.ByteString
    }

type Headers = [(S.ByteString, Text)]
type Pair = (Headers, Builder)

partToPair :: Part -> Pair
partToPair (Part contentType encoding disposition headers content) =
    (headers', builder)
  where
    headers' =
        ((:) ("Content-Type", contentType))
      $ (case encoding of
            None -> id
            Base64 -> (:) ("Content-Transfer-Encoding", "base64")
            QuotedPrintableText ->
                (:) ("Content-Transfer-Encoding", "quoted-printable")
            QuotedPrintableBinary ->
                (:) ("Content-Transfer-Encoding", "quoted-printable"))
      $ (case disposition of
            Nothing -> id
            Just fn ->
                (:) ("Content-Disposition", "attachment; filename="
                                            `T.append` fn))
      $ headers
    builder =
        case encoding of
            None -> fromWriteList writeByteString $ L.toChunks content
            Base64 -> base64 content
            QuotedPrintableText -> quotedPrintable True content
            QuotedPrintableBinary -> quotedPrintable False content

showPairs :: RandomGen g
          => Text -- ^ multipart type, eg mixed, alternative
          -> [Pair]
          -> g
          -> (Pair, g)
showPairs _ [] _ = error "renderParts called with null parts"
showPairs _ [pair] gen = (pair, gen)
showPairs mtype parts gen =
    ((headers, builder), gen')
  where
    (Boundary b, gen') = random gen
    headers =
        [ ("Content-Type", T.concat
            [ "multipart/"
            , mtype
            , "; boundary=\""
            , b
            , "\""
            ])
        ]
    builder = mconcat
        [ mconcat $ intersperse (fromByteString "\n")
                  $ map (showBoundPart $ Boundary b) parts
        , showBoundEnd $ Boundary b
        ]

-- | Render a 'Mail' with a given 'RandomGen' for producing boundaries.
renderMail :: RandomGen g => g -> Mail -> (L.ByteString, g)
renderMail g0 (Mail from to cc bcc headers parts) =
    (toLazyByteString builder, g'')
  where
    addressHeaders = map showAddressHeader [("From", [from]), ("To", to), ("Cc", cc), ("Bcc", bcc)]
    pairs = map (map partToPair) parts
    (pairs', g') = helper g0 $ map (showPairs "alternative") pairs
    helper :: g -> [g -> (x, g)] -> ([x], g)
    helper g [] = ([], g)
    helper g (x:xs) =
        let (b, g_) = x g
            (bs, g__) = helper g_ xs
         in (b : bs, g__)
    ((finalHeaders, finalBuilder), g'') = showPairs "mixed" pairs' g'
    builder = mconcat
        [ mconcat addressHeaders
        , mconcat $ map showHeader headers
        , showHeader ("MIME-Version", "1.0")
        , mconcat $ map showHeader finalHeaders
        , fromByteString "\n"
        , finalBuilder
        ]

showHeader :: (S.ByteString, Text) -> Builder
showHeader (k, v) = mconcat
    [ fromByteString k
    , fromByteString ": "
    , encodeIfNeeded v
    , fromByteString "\n"
    ]

showAddressHeader :: (S.ByteString, [Address]) -> Builder
showAddressHeader (k, as) =
  if null as
  then mempty
  else mconcat
    [ fromByteString k
    , fromByteString ": "
    , mconcat (intersperse (fromByteString ", ") . map showAddress $ as)
    , fromByteString "\n"
    ]

showAddress :: Address -> Builder
showAddress a = mconcat
    [ maybe mempty ((`mappend` fromByteString " ") . encodedWord) (addressName a)
    , fromByteString "<"
    , fromText (addressEmail a)
    , fromByteString ">"
    ]

showBoundPart :: Boundary -> (Headers, Builder) -> Builder
showBoundPart (Boundary b) (headers, content) = mconcat
    [ fromByteString "--"
    , fromText b
    , fromByteString "\n"
    , mconcat $ map showHeader headers
    , fromByteString "\n"
    , content
    ]

showBoundEnd :: Boundary -> Builder
showBoundEnd (Boundary b) = mconcat
    [ fromByteString "\n--"
    , fromText b
    , fromByteString "--"
    ]

-- | Like 'renderMail', but generates a random boundary.
renderMail' :: Mail -> IO L.ByteString
renderMail' m = do
    g <- getStdGen
    let (lbs, g') = renderMail g m
    setStdGen g'
    return lbs

-- | Send a fully-formed email message via the default sendmail
-- executable with default options.
sendmail :: L.ByteString -> IO ()
sendmail = sendmailCustom "/usr/sbin/sendmail" ["-t"]

-- | Render an email message and send via the default sendmail
-- executable with default options.
renderSendMail :: Mail -> IO ()
renderSendMail = sendmail <=< renderMail'

-- | Send a fully-formed email message via the specified sendmail
-- executable with specified options.
sendmailCustom :: FilePath        -- ^ sendmail executable path
                  -> [String]     -- ^ sendmail command-line options
                  -> L.ByteString -- ^ mail message as lazy bytestring
                  -> IO ()
sendmailCustom sm opts lbs = do
    (Just hin, _, _, phandle) <- createProcess $ 
                                 (proc sm opts) { std_in = CreatePipe }
    L.hPut hin lbs
    hClose hin
    exitCode <- waitForProcess phandle
    case exitCode of
        ExitSuccess -> return ()
        _ -> error $ "sendmail exited with error code " ++ show exitCode

-- | Render an email message and send via the specified sendmail
-- executable with specified options.
renderSendMailCustom :: FilePath    -- ^ sendmail executable path
                        -> [String] -- ^ sendmail command-line options
                        -> Mail     -- ^ mail to render and send
                        -> IO ()
renderSendMailCustom sm opts = sendmailCustom sm opts <=< renderMail'

-- FIXME usage of FilePath below can lead to issues with filename encoding

-- | A simple interface for generating an email with HTML and plain-text
-- alternatives and some file attachments.
--
-- Note that we use lazy IO for reading in the attachment contents.
simpleMail :: Address -- ^ to
           -> Address -- ^ from
           -> Text -- ^ subject
           -> LT.Text -- ^ plain body
           -> LT.Text -- ^ HTML body
           -> [(Text, FilePath)] -- ^ content type and path of attachments
           -> IO Mail
simpleMail to from subject plainBody htmlBody attachments = do
    as <- forM attachments $ \(ct, fn) -> do
        content <- L.readFile fn
        return (ct, fn, content)
    return Mail {
          mailFrom = from
        , mailTo   = [to]
        , mailCc   = []
        , mailBcc  = []
        , mailHeaders = [ ("Subject", subject) ]
        , mailParts =
            [ Part "text/plain; charset=utf-8" QuotedPrintableText Nothing []
            $ LT.encodeUtf8 plainBody
            , Part "text/html; charset=utf-8" QuotedPrintableText Nothing []
            $ LT.encodeUtf8 htmlBody
            ] :
            (map (\(ct, fn, content) ->
                    [Part ct Base64 (Just $ T.pack (takeFileName fn)) [] content]) as)
        }

data QP = QPPlain S.ByteString
        | QPNewline
        | QPTab
        | QPSpace
        | QPEscape S.ByteString

data QPC = QPCCR
         | QPCLF
         | QPCSpace
         | QPCTab
         | QPCPlain
         | QPCEscape
    deriving Eq

toQP :: Bool -- ^ text?
     -> L.ByteString
     -> [QP]
toQP isText =
    go
  where
    go lbs =
        case L.uncons lbs of
            Nothing -> []
            Just (c, rest) ->
                case toQPC c of
                    QPCCR -> go rest
                    QPCLF -> QPNewline : go rest
                    QPCSpace -> QPSpace : go rest
                    QPCTab -> QPTab : go rest
                    QPCPlain ->
                        let (x, y) = L.span ((== QPCPlain) . toQPC) lbs
                         in QPPlain (toStrict x) : go y
                    QPCEscape ->
                        let (x, y) = L.span ((== QPCEscape) . toQPC) lbs
                         in QPEscape (toStrict x) : go y

    toStrict = S.concat . L.toChunks

    toQPC :: Word8 -> QPC
    toQPC 13 | isText = QPCCR
    toQPC 10 | isText = QPCLF
    toQPC 9 = QPCTab
    toQPC 0x20 = QPCSpace
    toQPC 61 = QPCEscape
    toQPC w
        | 33 <= w && w <= 126 = QPCPlain
        | otherwise = QPCEscape

buildQPs :: [QP] -> Builder
buildQPs =
    go (0 :: Int)
  where
    go _ [] = mempty
    go currLine (qp:qps) =
        case qp of
            QPNewline -> copyByteString "\r\n" `mappend` go 0 qps
            QPTab -> wsHelper (copyByteString "=09") (fromWord8 9)
            QPSpace -> wsHelper (copyByteString "=20") (fromWord8 0x20)
            QPPlain bs ->
                let toTake = 75 - currLine
                    (x, y) = S.splitAt toTake bs
                    rest
                        | S.null y = qps
                        | otherwise = QPPlain y : qps
                 in helper (S.length x) (copyByteString x) rest
            QPEscape bs ->
                let toTake = (75 - currLine) `div` 3
                    (x, y) = S.splitAt toTake bs
                    rest
                        | S.null y = qps
                        | otherwise = QPEscape y : qps
                 in if toTake == 0
                        then copyByteString "\r\n" `mappend` go 0 (qp:qps)
                        else helper (S.length x * 3) (escape x) rest
      where
        escape =
            S.foldl' add mempty
          where
            add builder w =
                builder `mappend` escaped
              where
                escaped = fromWord8 61 `mappend` hex (w `shiftR` 4)
                                       `mappend` hex (w .&. 15)

        helper added builder rest =
            builder' `mappend` go newLine rest
           where
             (newLine, builder')
                | added + currLine >= 75 =
                    (0, builder `mappend` copyByteString "=\r\n")
                | otherwise = (added + currLine, builder)

        wsHelper enc raw
            | null qps =
                if currLine <= 73
                    then enc
                    else copyByteString "\r\n=" `mappend` enc
            | otherwise = helper 1 raw qps

-- | The first parameter denotes whether the input should be treated as text.
-- If treated as text, then CRs will be stripped and LFs output as CRLFs. If
-- binary, then CRs and LFs will be escaped.
quotedPrintable :: Bool -> L.ByteString -> Builder
quotedPrintable isText = buildQPs . toQP isText

hex :: Word8 -> Builder
hex x
    | x < 10 = fromWord8 $ x + 48
    | otherwise = fromWord8 $ x + 55

encodeIfNeeded :: Text -> Builder
encodeIfNeeded t =
  if needsEncodedWord t
  then encodedWord t
  else fromText t

needsEncodedWord :: Text -> Bool
needsEncodedWord = not . T.all isAscii

encodedWord :: Text -> Builder
encodedWord t = mconcat
    [ fromByteString "=?utf-8?Q?"
    , S.foldl' go mempty $ TE.encodeUtf8 t
    , fromByteString "?="
    ]
  where
    go front w = front `mappend` go' w
    go' 32 = fromWord8 95 -- space
    go' 95 = go'' 95 -- _
    go' 63 = go'' 63 -- ?
    go' 61 = go'' 61 -- =

    -- The special characters from RFC 2822. Not all of these always give
    -- problems, but at least @[];"<>, gave problems with some mail servers
    -- when used in the 'name' part of an address.
    go' 34 = go'' 34 -- "
    go' 40 = go'' 40 -- (
    go' 41 = go'' 41 -- )
    go' 44 = go'' 44 -- ,
    go' 46 = go'' 46 -- .
    go' 58 = go'' 58 -- ;
    go' 59 = go'' 59 -- ;
    go' 60 = go'' 60 -- <
    go' 62 = go'' 62 -- >
    go' 64 = go'' 64 -- @
    go' 91 = go'' 91 -- [
    go' 92 = go'' 92 -- \
    go' 93 = go'' 93 -- ]
    go' w
        | 33 <= w && w <= 126 = fromWord8 w
        | otherwise = go'' w
    go'' w = fromWord8 61 `mappend` hex (w `shiftR` 4)
                          `mappend` hex (w .&. 15)

-- 57 bytes, when base64-encoded, becomes 76 characters.
-- Perform the encoding 57-bytes at a time, and then append a newline.
base64 :: L.ByteString -> Builder
base64 lbs
    | L.null lbs = mempty
    | otherwise = fromByteString x64 `mappend`
                  fromByteString "\r\n" `mappend`
                  base64 y
  where
    (x', y) = L.splitAt 57 lbs
    x = S.concat $ L.toChunks x'
    x64 = Base64.encode x
