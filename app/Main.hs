{- birch-beer
Gregory W. Schwartz

Displays a hierarchical tree of clusters with colors, scaling, and more.
-}

{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators     #-}

module Main where

-- Remote
import Control.Monad (when)
import Data.Colour.SRGB (sRGB24read)
import Data.Maybe (fromMaybe)
import Options.Generic
import qualified Control.Lens as L
import qualified Data.Aeson as A
import qualified Data.Sparse.Common as S
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Diagrams.Backend.Cairo as D
import qualified Diagrams.Prelude as D
import qualified H.Prelude as H

-- Local
import BirchBeer.Load
import BirchBeer.ColorMap
import BirchBeer.Interactive
import BirchBeer.MainDiagram
import BirchBeer.Types
import BirchBeer.Utility

-- | Command line arguments
data Options = Options
    { input :: String <?> "(FILE) The input JSON file."
    , output :: Maybe String <?> "([dendrogram.pdf] | FILE) The output file."
    , delimiter :: Maybe Char <?> "([,] | CHAR) The delimiter for csv files."
    , labelsFile :: Maybe String <?> "([Nothing] | FILE) The input file containing the label for each item, with \"item,label\" header."
    , minSize :: Maybe Int <?> "([1] | INT) The minimum size of a cluster. Defaults to 1."
    , maxStep :: Maybe Int <?> "([Nothing] | INT) Only keep clusters that are INT steps from the root. Defaults to all steps."
    , drawLeaf :: Maybe String <?> "([DrawText] | DrawItem DrawItemType) How to draw leaves in the dendrogram. DrawText is the number of cells in that leaf. DrawItem is the collection of cells represented by circles, consisting of: DrawItem DrawLabel, where each cell is colored by its label, DrawItem (DrawContinuous GENE), where each cell is colored by the expression of GENE (corresponding to a gene name in the input matrix), DrawItem (DrawThresholdContinuous [(GENE, DOUBLE)], where each cell is colored by the binary high / low expression of GENE based on DOUBLE and multiple GENEs can be used to combinatorically label cells (GENE1 high / GENE2 low, etc.), and DrawItem DrawSumContinuous, where each cell is colored by the sum of the post-normalized columns (use --normalization NoneNorm for UMI counts, default). The default is DrawText, unless --labels-file is provided, in which DrawItem DrawLabel is the default."
    , drawPie :: Maybe String <?> "([PieRing] | PieChart | PieNone) How to draw cell leaves in the dendrogram. PieRing draws a pie chart ring around the cells. PieChart only draws a pie chart instead of cells. PieNone only draws cells, no pie rings or charts."
    , drawMark :: Maybe String <?> "([MarkNone] | MarkModularity) How to draw annotations around each inner node in the tree. MarkNone draws nothing and MarkModularity draws a black circle representing the modularity at that node, darker black means higher modularity for that next split."
    , drawNodeNumber :: Bool <?> "Draw the node numbers on top of each node in the graph."
    , drawMaxNodeSize :: Maybe Double <?> "([72] | DOUBLE) The max node size when drawing the graph. 36 is the theoretical default, but here 72 makes for thicker branches."
    , drawNoScaleNodes :: Bool <?> "Do not scale inner node size when drawing the graph. Instead, uses draw-max-node-size as the size of each node and is highly recommended to change as the default may be too large for this option."
    , drawColors :: Maybe String <?> "([Nothing] | COLORS) Custom colors for the labels. Will repeat if more labels than provided colors. For instance: --draw-colors \"[\\\"#e41a1c\\\", \\\"#377eb8\\\"]\""
    , interactive :: Bool <?> "Display interactive tree."
    } deriving (Generic)

modifiers :: Modifiers
modifiers = lispCaseModifiers { shortNameModifier = short }
  where
    short "minSize"              = Just 'M'
    short "drawLeaf"             = Just 'L'
    short "drawDendrogram"       = Just 'D'
    short "drawNodeNumber"       = Just 'N'
    short "drawColors"           = Just 'R'
    short "interactive"          = Just 'I'
    short x                      = firstLetter x

instance ParseRecord Options where
    parseRecord = parseRecordWithModifiers modifiers

main :: IO ()
main = do
    opts <- getRecord "birch-beer, Gregory W. Schwartz.\
                      \ Displays a hierarchical tree of clusters with colors,\
                      \ scaling, and more."

    let input'            = unHelpful . input $ opts
        delimiter'        =
            Delimiter . fromMaybe ',' . unHelpful . delimiter $ opts
        labelsFile'       = fmap LabelFile . unHelpful . labelsFile $ opts
        minSize'          = fmap MinClusterSize . unHelpful . minSize $ opts
        maxStep'          = fmap MaxStep . unHelpful . maxStep $ opts
        drawLeaf'         =
            maybe (maybe DrawText (const (DrawItem DrawLabel)) labelsFile') read
                . unHelpful
                . drawLeaf
                $ opts
        drawPie'          = maybe PieRing read . unHelpful . drawPie $ opts
        drawMark'         = maybe MarkNone read . unHelpful . drawMark $ opts
        drawNodeNumber'   = DrawNodeNumber . unHelpful . drawNodeNumber $ opts
        drawMaxNodeSize'  =
            DrawMaxNodeSize . fromMaybe 72 . unHelpful . drawMaxNodeSize $ opts
        drawNoScaleNodes' =
            DrawNoScaleNodesFlag . unHelpful . drawNoScaleNodes $ opts
        drawColors'       = fmap ( CustomColors
                                 . fmap sRGB24read
                                 . (\x -> read x :: [String])
                                 )
                          . unHelpful
                          . drawColors
                          $ opts
        output'           =
            fromMaybe "dendrogram.pdf" . unHelpful . output $ opts

    dend <- loadDend input'
    
    -- Get the label map from either a file or from expression thresholds.
    labelMap <- case drawLeaf' of
                    (DrawItem (DrawThresholdContinuous gs)) ->
                        error "Threshold not supported here."
                        -- fmap
                        --     ( Just
                        --     . getLabelMapThresholdContinuous
                        --         (fmap (L.over L._1 Feature) gs)
                        --     . fromMaybe (error "Requires matrix.")
                        --     )
                        --     mat
                    _ -> sequence . fmap (loadLabelData delimiter') $ labelsFile'


    let config :: Config T.Text (S.SpMatrix Double)
        config = Config { _birchLabelMap = labelMap
                        , _birchMinStep = minSize'
                        , _birchMaxStep = maxStep'
                        , _birchDrawLeaf = drawLeaf'
                        , _birchDrawPie = drawPie'
                        , _birchDrawMark = drawMark'
                        , _birchDrawNodeNumber = drawNodeNumber'
                        , _birchDrawMaxNodeSize = drawMaxNodeSize'
                        , _birchDrawNoScaleNodes = drawNoScaleNodes'
                        , _birchDrawColors = drawColors'
                        , _birchDend = dend
                        , _birchMat = Nothing
                        }

    (plot, _, _, _, _, _) <- mainDiagram config

    D.renderCairo
            output'
            (D.mkHeight 1000)
            plot

    when (unHelpful . interactive $ opts) $ interactiveDiagram dend labelMap (Nothing :: Maybe (S.SpMatrix Double))

    return ()
