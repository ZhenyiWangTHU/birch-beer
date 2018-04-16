{- BirchBeer.Interactive
Gregory W. Schwartz

Interactive version of the tree.
-}

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}

module BirchBeer.Interactive
    ( interactiveDiagram
    ) where

-- Remote
import Data.Bool (bool)
import Data.Colour.SRGB (sRGB24reads)
import Data.Maybe (catMaybes)
import Safe (headMay)
import Text.Read (readMaybe)
import System.IO.Temp (withTempFile)
import qualified Control.Lens as L
import qualified Data.Clustering.Hierarchical as HC
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Diagrams.Backend.Cairo as D
import qualified Diagrams.Backend.Gtk as D
import qualified Diagrams.Prelude as D
import qualified Graphics.UI.Gtk as Gtk
import qualified System.IO as IO
import qualified Typed.Spreadsheet as TS

-- Local
import BirchBeer.MainDiagram
import BirchBeer.Types

-- | Interactive version of the tree.
interactiveDiagram
    :: (Eq a, Ord a, TreeItem a, MatrixLike b)
    => HC.Dendrogram (V.Vector a) -> Maybe LabelMap -> Maybe b -> IO ()
interactiveDiagram dend labelMap mat = graphicalUI' "birch-beer" $ do
    minSize'  <-
        fmap (MinClusterSize . round) $ TS.spinButtonAt 1 "Minimum cluster size" 1
    maxStep' <- fmap (MaxStep . round)
               $ TS.spinButtonAt 1000 "Maximum number of steps from root" 1
    drawLeafTemp <- TS.radioButton
                        "Leaf type"
                        DrawText
                        [ DrawItem DrawLabel
                        , DrawItem DrawSumContinuous
                        , DrawItem (DrawContinuous "GENE")
                        ]
    drawContinuousGene' <- TS.entry "GENE for DrawItem DrawContinuous"
    drawPie' <- TS.radioButton "Leaf shape" PieRing [PieChart, PieNone]
    drawMark' <- TS.radioButton "Node mark" MarkNone [MarkModularity]
    drawNodeNumber' <- fmap DrawNodeNumber $ TS.checkBox "Show node number"
    drawMaxNodeSize' <-
        fmap DrawMaxNodeSize
            $ TS.spinButtonAt 72 "Maximum size of drawn node" 1
    drawNoScaleNodes' <-
        fmap DrawNoScaleNodesFlag $ TS.checkBox "Do not scale nodes"
    drawColors' <- fmap
                    (\ x
                    -> ( (\xs -> if null xs then Nothing else Just $ CustomColors xs)
                         . catMaybes
                         . fmap (fmap fst . headMay . sRGB24reads)
                       )
                   =<< ( (\x -> readMaybe x :: Maybe [String])
                       . T.unpack
                       $ x
                       )
                    )
                 $ TS.entryAt "[]" "Custom node colors [\"#e41a1c\", \"#377eb8\"]"

    return $
        let drawLeaf' = case drawLeafTemp of
                            DrawItem (DrawContinuous _) ->
                                DrawItem (DrawContinuous drawContinuousGene')
                            x -> x
            config = Config { _birchLabelMap = labelMap
                            , _birchMinStep = Just minSize'
                            , _birchMaxStep = Just maxStep'
                            , _birchDrawLeaf = drawLeaf'
                            , _birchDrawPie = drawPie'
                            , _birchDrawMark = drawMark'
                            , _birchDrawNodeNumber = drawNodeNumber'
                            , _birchDrawMaxNodeSize = drawMaxNodeSize'
                            , _birchDrawNoScaleNodes = drawNoScaleNodes'
                            , _birchDrawColors = drawColors'
                            , _birchDend = dend
                            , _birchMat = mat
                            }
        in fmap (L.view L._1) $ mainDiagram config

-- | Build a `Diagram`-based user interface using an IO updatable.
graphicalUI'
    :: T.Text
    -> TS.Updatable (IO (D.Diagram D.Cairo))
    ->
       -- ^ Program logic
       IO ()
graphicalUI' = TS.ui setupGraphical processGraphicalEvent
  where
    setupGraphical :: Gtk.HBox -> IO Gtk.DrawingArea
    setupGraphical hBox = do
        drawingArea <- Gtk.drawingAreaNew
        Gtk.boxPackStart hBox drawingArea Gtk.PackGrow 0
        return drawingArea
    processGraphicalEvent :: Gtk.DrawingArea -> IO (D.Diagram D.Cairo) -> IO ()
    processGraphicalEvent drawingArea diagramIO = do
        diagram <- diagramIO

        drawWindow <- Gtk.widgetGetDrawWindow drawingArea
        (w, h) <- Gtk.widgetGetSize drawingArea

        let w' = fromIntegral (w :: Int) / 2
            h' = fromIntegral (h :: Int) / 2
            minSize = fromIntegral $ min w h
            maxIsWidth =
                if max (D.width diagram) (D.height diagram) == D.width diagram
                    then True
                    else False
            resizeFunc =
                bool (D.scaleUToY minSize) (D.scaleUToY minSize) maxIsWidth
            diagram' = diagram
                   D.# D.toGtkCoords
                   D.# resizeFunc
                   D.# D.center
                   D.# D.moveTo (D.p2 (w', h'))

        D.renderToGtk drawWindow diagram'

-- | Build a `Diagram`-based user interface using an IO updatable. Draws to a
-- png first.
graphicalUIPng'
    :: T.Text
    -> TS.Updatable (IO (D.Diagram D.Cairo))
    ->
       -- ^ Program logic
       IO ()
graphicalUIPng' title updatable = withTempFile "." "temp_tree.png" $ \file h -> do
    TS.ui setupGraphical (processGraphicalEvent file h) title updatable
  where
    setupGraphical :: Gtk.HBox -> IO Gtk.DrawingArea
    setupGraphical hBox = do
        drawingArea <- Gtk.drawingAreaNew
        Gtk.boxPackStart hBox drawingArea Gtk.PackGrow 0
        return drawingArea
    processGraphicalEvent :: FilePath -> IO.Handle -> Gtk.DrawingArea -> IO (D.Diagram D.Cairo) -> IO ()
    processGraphicalEvent file h drawingArea diagramIO = do
        dia <- diagramIO

        D.renderCairo
            file
            (D.mkHeight 1000)
            dia

        IO.hClose h

        diagram <- fmap (either mempty D.image) $ D.loadImageEmb file

        drawWindow <- Gtk.widgetGetDrawWindow drawingArea
        (w, h) <- Gtk.widgetGetSize drawingArea

        let w' = fromIntegral (w :: Int) / 2
            h' = fromIntegral (h :: Int) / 2
            minSize = fromIntegral $ min w h
            maxIsWidth =
                if max (D.width diagram) (D.height diagram) == D.width diagram
                    then True
                    else False
            resizeFunc =
                bool (D.scaleUToY minSize) (D.scaleUToY minSize) maxIsWidth
            diagram' = diagram
                   D.# D.toGtkCoords
                   D.# resizeFunc
                   D.# D.center
                   D.# D.moveTo (D.p2 (w', h'))

        D.renderToGtk drawWindow diagram'