import Foundation

/// Every layer the app knows about, in one list, registered once at launch.
///
/// Order within a group is the order the panel shows, so the cheap and generally
/// useful ones come first and the expensive or situational ones come last.
enum LayerCatalog {

    static func buildAndRegister() {
        var layers: [AILayer] = []

        // Vision — reading the main detector first, since these cost nothing.
        layers += [
            ObjectLabelLayer(),
            TrackingLayer(),
            FaceLayer(),
            BodyPoseLayer(),
            HandPoseLayer(),
            FaceLandmarkLayer(),
            AnimalLayer(),
            SceneClassifyLayer(),
            ColourAttributeLayer(),
            SceneTextLayer(),
            PlateLayer(),
            BarcodeLayer(),
            OrientedBoxLayer(),
            HorizonLayer(),
            PersonSegmentationLayer(),
            InstanceMaskLayer(),
            SaliencyLayer(attention: true),
            SaliencyLayer(attention: false),
            OpticalFlowLayer(),
            TrajectoryLayer(),
            ReIdentificationLayer(),
            SceneAnomalyLayer(),
            // Downloaded Core ML models rather than Apple framework requests.
            MonocularDepthLayer(),
            SemanticSegmentationLayer()
        ]
        layers += UnavailableLayer.visionGaps()

        // Audio and speech.
        layers += [
            VoiceActivityLayer(),
            SoundEventLayer(),
            NoiseProfileLayer(),
            TranscriptionLayer()
        ]

        // Language.
        layers += [
            SentimentLayer(),
            EntityLayer(),
            KeywordLayer(),
            LanguageIDLayer(),
            // Apple's own on-device language model and translator — no download.
            SummarizationLayer(),
            QuestionAnsweringLayer(),
            OnDeviceTranslationLayer()
        ]
        layers += LanguageLayerGaps.all()
        layers += AudioLayerGaps.all()

        // Multimodal — the local fusions first, the ones that leave the device last.
        layers += [
            LiveCaptionLayer(),
            AudioVisualFusionLayer(),
            AudioVisualAnomalyLayer(),
            SceneDescriptionLayer(),
            GroundingLayer()
        ]
        layers += MultimodalGaps.all()

        // Sensors.
        layers += [
            MotionSensorLayer(),
            DepthLayer(),
            ThermalLayer()
        ]

        // Analytics.
        layers += [
            ZoneOccupancyLayer(),
            LineCrossingLayer(),
            HeatmapLayer(),
            BehaviourFlagsLayer(),
            TrendLayer()
        ]

        // Privacy.
        layers += [
            PrivacyBlurLayer(),
            RegionRedactionLayer()
        ]

        LayerRegistry.shared.register(layers)
        // Anything downloaded on a previous run is loaded now, so a layer the
        // operator already paid the download for is warm at launch.
        for id in ModelStore.manifest.keys { ModelStore.shared.loadIfPresent(id) }
        LayerGeometry.shared.refreshCaches()
        EventLog.action("layers.registered", [
            "total": layers.count,
            "usable": layers.filter { $0.availability.isUsable }.count,
            "active": LayerRegistry.shared.activeIDs.count
        ])
    }
}
