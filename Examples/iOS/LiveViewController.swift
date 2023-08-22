import AVFoundation
import HaishinKit
import Photos
import UIKit
import VideoToolbox

final class LiveViewController: UIViewController {
    private static let maxRetryCount: Int = 5

    @IBOutlet private weak var currentFPSLabel: UILabel!
    @IBOutlet private weak var publishButton: UIButton!
    @IBOutlet private weak var pauseButton: UIButton!
    @IBOutlet private weak var videoBitrateLabel: UILabel!
    @IBOutlet private weak var videoBitrateSlider: UISlider!
    @IBOutlet private weak var audioBitrateLabel: UILabel!
    @IBOutlet private weak var zoomSlider: UISlider!
    @IBOutlet private weak var audioBitrateSlider: UISlider!
    @IBOutlet private weak var fpsControl: UISegmentedControl!
    @IBOutlet private weak var effectSegmentControl: UISegmentedControl!
    @IBOutlet private weak var audioDevicePicker: UIPickerView!
    @IBOutlet private weak var audioMonoStereoSegmentCOntrol: UISegmentedControl!

    private var pipIntentView = UIView()
    private var rtmpConnection = RTMPConnection()
    private var rtmpStream: RTMPStream!
    private var sharedObject: RTMPSharedObject!
    private var currentEffect: VideoEffect?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var retryCount: Int = 0
    private var videoBitRate = VideoCodecSettings.default.bitRate
    private var preferedStereo = false

    override func viewDidLoad() {
        super.viewDidLoad()

        rtmpConnection.delegate = self

        pipIntentView.layer.borderWidth = 1.0
        pipIntentView.layer.borderColor = UIColor.white.cgColor
        pipIntentView.bounds = MultiCamCaptureSettings.default.regionOfInterest
        pipIntentView.isUserInteractionEnabled = true
        view.addSubview(pipIntentView)

        rtmpStream = RTMPStream(connection: rtmpConnection)
        if let orientation = DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) {
            rtmpStream.videoOrientation = orientation
        }

        rtmpStream.loopback = DeviceUtil.isHeadphoneConnected()

        rtmpStream.audioSettings = AudioCodecSettings(
            bitRate: 64 * 1000
        )

        rtmpStream.videoSettings = VideoCodecSettings(
            videoSize: .init(width: 854, height: 480),
            profileLevel: kVTProfileLevel_H264_Baseline_3_1 as String,
            bitRate: 640 * 1000,
            maxKeyFrameIntervalDuration: 2,
            scalingMode: .trim,
            bitRateMode: .average,
            allowFrameReordering: nil,
            isHardwareEncoderEnabled: true
        )

        rtmpStream.mixer.recorder.delegate = self
        videoBitrateSlider?.value = Float(VideoCodecSettings.default.bitRate) / 1000
        audioBitrateSlider?.value = Float(AudioCodecSettings.default.bitRate) / 1000

        NotificationCenter.default.addObserver(self, selector: #selector(on(_:)), name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        logger.info("viewWillAppear")
        super.viewWillAppear(animated)
        let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition)

        // If you're using multi-camera functionality, please make sure to call the attachMultiCamera method first. This is required for iOS 14 and 15, among others.
        if #available(iOS 13.0, *) {
            let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            rtmpStream.videoCapture(for: 1)?.isVideoMirrored = true
            rtmpStream.attachMultiCamera(front)
        }
        rtmpStream.attachCamera(back) { error in
            logger.warn(error)
        }
        rtmpStream.attachAudio(AVCaptureDevice.default(for: .audio), automaticallyConfiguresApplicationAudioSession: false) { error in
            logger.warn(error)
        }
        rtmpStream.addObserver(self, forKeyPath: "currentFPS", options: .new, context: nil)
        (view as? NetStreamDrawable)?.attachStream(rtmpStream)
        NotificationCenter.default.addObserver(self, selector: #selector(didInterruptionNotification(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didRouteChangeNotification(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        logger.info("viewWillDisappear")
        super.viewWillDisappear(animated)
        rtmpStream.removeObserver(self, forKeyPath: "currentFPS")
        rtmpStream.close()
        rtmpStream.attachAudio(nil)
        rtmpStream.attachCamera(nil)
        if #available(iOS 13.0, *) {
            rtmpStream.attachMultiCamera(nil)
        }
        // swiftlint:disable:next notification_center_detachment
        NotificationCenter.default.removeObserver(self)
    }

    // swiftlint:disable:next block_based_kvo
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if Thread.isMainThread {
            currentFPSLabel?.text = "\(rtmpStream.currentFPS)"
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else {
            return
        }
        if touch.view == pipIntentView {
            let destLocation = touch.location(in: view)
            let prevLocation = touch.previousLocation(in: view)
            var currentFrame = pipIntentView.frame
            let deltaX = destLocation.x - prevLocation.x
            let deltaY = destLocation.y - prevLocation.y
            currentFrame.origin.x += deltaX
            currentFrame.origin.y += deltaY
            pipIntentView.frame = currentFrame
            rtmpStream.multiCamCaptureSettings = MultiCamCaptureSettings(
                mode: rtmpStream.multiCamCaptureSettings.mode,
                cornerRadius: 16.0,
                regionOfInterest: currentFrame,
                direction: .east
            )
        }
    }

    @IBAction func rotateCamera(_ sender: UIButton) {
        logger.info("rotateCamera")
        let position: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
        rtmpStream.videoCapture(for: 0)?.isVideoMirrored = position == .front
        rtmpStream.attachCamera(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)) { error in
            logger.warn(error)
        }
        if #available(iOS 13.0, *) {
            rtmpStream.videoCapture(for: 1)?.isVideoMirrored = currentPosition == .front
            rtmpStream.attachMultiCamera(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition)) { error in
                logger.warn(error)
            }
        }
        currentPosition = position
    }

    @IBAction func toggleTorch(_ sender: UIButton) {
        rtmpStream.torch.toggle()
    }

    @IBAction func on(slider: UISlider) {
        if slider == audioBitrateSlider {
            audioBitrateLabel?.text = "audio \(Int(slider.value))/kbps"
            rtmpStream.audioSettings.bitRate = Int(slider.value * 1000)
        }
        if slider == videoBitrateSlider {
            videoBitrateLabel?.text = "video \(Int(slider.value))/kbps"
            rtmpStream.videoSettings.bitRate = UInt32(slider.value * 1000)
        }
        if slider == zoomSlider {
            let zoomFactor = CGFloat(slider.value)
            guard let device = rtmpStream.videoCapture(for: 0)?.device, 1 <= zoomFactor && zoomFactor < device.activeFormat.videoMaxZoomFactor else {
                return
            }
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: zoomFactor, withRate: 5.0)
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for ramp: \(error)")
            }
        }
    }

    @IBAction func on(pause: UIButton) {
        rtmpStream.paused.toggle()
    }

    @IBAction func on(close: UIButton) {
        self.dismiss(animated: true, completion: nil)
    }

    @IBAction func on(publish: UIButton) {
        if publish.isSelected {
            UIApplication.shared.isIdleTimerDisabled = false
            rtmpConnection.close()
            rtmpConnection.removeEventListener(.rtmpStatus, selector: #selector(rtmpStatusHandler), observer: self)
            rtmpConnection.removeEventListener(.ioError, selector: #selector(rtmpErrorHandler), observer: self)
            publish.setTitle("●", for: [])
        } else {
            UIApplication.shared.isIdleTimerDisabled = true
            rtmpConnection.addEventListener(.rtmpStatus, selector: #selector(rtmpStatusHandler), observer: self)
            rtmpConnection.addEventListener(.ioError, selector: #selector(rtmpErrorHandler), observer: self)
            rtmpConnection.connect(Preference.defaultInstance.uri!)
            publish.setTitle("■", for: [])
        }
        publish.isSelected.toggle()
    }

    @objc
    private func rtmpStatusHandler(_ notification: Notification) {
        let e = Event.from(notification)
        guard let data: ASObject = e.data as? ASObject, let code: String = data["code"] as? String else {
            return
        }
        logger.info(code)
        switch code {
        case RTMPConnection.Code.connectSuccess.rawValue:
            retryCount = 0
            rtmpStream.publish(Preference.defaultInstance.streamName!)
        // sharedObject!.connect(rtmpConnection)
        case RTMPConnection.Code.connectFailed.rawValue, RTMPConnection.Code.connectClosed.rawValue:
            guard retryCount <= LiveViewController.maxRetryCount else {
                return
            }
            Thread.sleep(forTimeInterval: pow(2.0, Double(retryCount)))
            rtmpConnection.connect(Preference.defaultInstance.uri!)
            retryCount += 1
        default:
            break
        }
    }

    @objc
    private func rtmpErrorHandler(_ notification: Notification) {
        logger.error(notification)
        rtmpConnection.connect(Preference.defaultInstance.uri!)
    }

    func tapScreen(_ gesture: UIGestureRecognizer) {
        if let gestureView = gesture.view, gesture.state == .ended {
            let touchPoint: CGPoint = gesture.location(in: gestureView)
            let pointOfInterest = CGPoint(x: touchPoint.x / gestureView.bounds.size.width, y: touchPoint.y / gestureView.bounds.size.height)
            guard
                let device = rtmpStream.videoCapture(for: 0)?.device, device.isFocusPointOfInterestSupported else {
                return
            }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = pointOfInterest
                device.focusMode = .continuousAutoFocus
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for focusPointOfInterest: \(error)")
            }
        }
    }

    private func setEnabledPreferredInputBuiltInMic(_ isEnabled: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if isEnabled {
                guard
                    let availableInputs = session.availableInputs,
                    let builtInMicInput = availableInputs.first(where: { $0.portType == .builtInMic }) else {
                    return
                }
                try session.setPreferredInput(builtInMicInput)
            } else {
                try session.setPreferredInput(nil)
            }
        } catch {
        }
    }

    @IBAction private func onFPSValueChanged(_ segment: UISegmentedControl) {
        switch segment.selectedSegmentIndex {
        case 0:
            rtmpStream.frameRate = 15
        case 1:
            rtmpStream.frameRate = 30
        case 2:
            rtmpStream.frameRate = 60
        default:
            break
        }
    }

    @IBAction private func onEffectValueChanged(_ segment: UISegmentedControl) {
        if let currentEffect: VideoEffect = currentEffect {
            _ = rtmpStream.unregisterVideoEffect(currentEffect)
        }
        switch segment.selectedSegmentIndex {
        case 1:
            currentEffect = MonochromeEffect()
            _ = rtmpStream.registerVideoEffect(currentEffect!)
        case 2:
            currentEffect = PronamaEffect()
            _ = rtmpStream.registerVideoEffect(currentEffect!)
        default:
            break
        }
    }

    @IBAction private func onStereoMonoChanged(_ segment: UISegmentedControl) {
        switch segment.selectedSegmentIndex {
        case 0:
            preferedStereo = false
        case 1:
            preferedStereo = true
            pickerView(audioDevicePicker, didSelectRow: audioDevicePicker.selectedRow(inComponent: 0), inComponent: 0)
        default:
            break
        }
    }

    @objc
    private func didInterruptionNotification(_ notification: Notification) {
        logger.info(notification)
    }

    @objc
    private func didRouteChangeNotification(_ notification: Notification) {
        logger.info(notification)
        if AVAudioSession.sharedInstance().inputDataSources?.isEmpty == true {
            setEnabledPreferredInputBuiltInMic(false)
            audioMonoStereoSegmentCOntrol.isHidden = true
            audioDevicePicker.isHidden = true
        } else {
            setEnabledPreferredInputBuiltInMic(true)
            audioMonoStereoSegmentCOntrol.isHidden = false
            audioDevicePicker.isHidden = false
        }
        audioDevicePicker.reloadAllComponents()
        if DeviceUtil.isHeadphoneDisconnected(notification) {
            rtmpStream.loopback = false
        } else {
            rtmpStream.loopback = DeviceUtil.isHeadphoneConnected()
        }
    }

    @objc
    private func on(_ notification: Notification) {
        guard let orientation = DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) else {
            return
        }
        rtmpStream.videoOrientation = orientation
    }
}

extension LiveViewController: RTMPConnectionDelegate {
    func connection(_ connection: RTMPConnection, publishInsufficientBWOccured stream: RTMPStream) {
        // Adaptive bitrate streaming exsample. Please feedback me your good algorithm. :D
        videoBitRate -= 32 * 1000
        stream.videoSettings.bitRate = max(videoBitRate, 64 * 1000)
    }

    func connection(_ connection: RTMPConnection, publishSufficientBWOccured stream: RTMPStream) {
        videoBitRate += 32 * 1000
        stream.videoSettings.bitRate = min(videoBitRate, VideoCodecSettings.default.bitRate)
    }

    func connection(_ connection: RTMPConnection, updateStats stream: RTMPStream) {
    }

    func connection(_ connection: RTMPConnection, didClear stream: RTMPStream) {
        videoBitRate = VideoCodecSettings.default.bitRate
    }
}

extension LiveViewController: IORecorderDelegate {
    // MARK: IORecorderDelegate
    func recorder(_ recorder: IORecorder, errorOccured error: IORecorder.Error) {
        logger.error(error)
    }

    func recorder(_ recorder: IORecorder, finishWriting writer: AVAssetWriter) {
        PHPhotoLibrary.shared().performChanges({() -> Void in
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: writer.outputURL)
        }, completionHandler: { _, error -> Void in
            do {
                try FileManager.default.removeItem(at: writer.outputURL)
            } catch {
                print(error)
            }
        })
    }
}

extension LiveViewController: UIPickerViewDelegate {
    // MARK: UIPickerViewDelegate
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        let session = AVAudioSession.sharedInstance()
        guard let preferredInput = session.preferredInput,
              let newDataSource = preferredInput.dataSources?[row],
              let supportedPolarPatterns = newDataSource.supportedPolarPatterns else {
            return
        }
        do {
            if #available(iOS 14.0, *) {
                if preferedStereo && supportedPolarPatterns.contains(.stereo) {
                    try newDataSource.setPreferredPolarPattern(.stereo)
                    logger.info("stereo")
                } else {
                    audioMonoStereoSegmentCOntrol.selectedSegmentIndex = 0
                    logger.info("mono")
                }
            }
            try preferredInput.setPreferredDataSource(newDataSource)
        } catch {
            logger.warn("can't set supported setPreferredDataSource")
        }
        rtmpStream.attachAudio(AVCaptureDevice.default(for: .audio), automaticallyConfiguresApplicationAudioSession: false) { error in
            logger.warn(error)
        }
    }
}

extension LiveViewController: UIPickerViewDataSource {
    // MARK: UIPickerViewDataSource
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return AVAudioSession.sharedInstance().preferredInput?.dataSources?.count ?? 0
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return AVAudioSession.sharedInstance().preferredInput?.dataSources?[row].dataSourceName ?? ""
    }
}
