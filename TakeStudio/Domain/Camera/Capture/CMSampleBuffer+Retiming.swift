import AVFoundation
import CoreMedia

extension CMSampleBuffer {
    /// Deep PCM copy for buffers queued before the writer session starts.
    func deepCopyPCM() -> CMSampleBuffer? {
        guard
            CMSampleBufferGetNumSamples(self) > 0,
            let formatDescription = CMSampleBufferGetFormatDescription(self)
        else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }

        var timing = CMSampleTimingInfo()
        status = CMSampleBufferGetSampleTimingInfo(self, at: 0, timingInfoOut: &timing)
        guard status == noErr else { return nil }

        let sampleCount = CMSampleBufferGetNumSamples(self)
        var copy: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &copy
        )
        guard status == noErr else { return nil }
        return copy
    }

    func retimed(to presentationTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(self),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var retimedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: self,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimedBuffer
        )
        guard status == noErr else { return nil }
        return retimedBuffer
    }
}
