/**
 * Silero VAD Web Adapter
 * Wraps onnxruntime-web into a simple API for Flutter web interop.
 */
class SileroVADAdapter {
  constructor() {
    this.session = null;
    this.state = null;
  }

  /**
   * Initialize VAD with ONNX model binary.
   * @param {Uint8Array} bytes - The silero_vad.onnx file bytes
   */
  async initialize(bytes) {
    try {
      // Convert Uint8Array (from Dart Uint8List) to proper ArrayBuffer
      const modelData = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      this.session = await ort.InferenceSession.create(modelData);
      this.state = new Float32Array(256); // [2][1][128] zero-initialized
      return 'ok';
    } catch (e) {
      return 'error: ' + e.message;
    }
  }

  /**
   * Process a 512-sample Float32 audio frame.
   * @param {Float32Array} audioData - 512 float32 samples
   * @returns {number} speech probability (0.0 ~ 1.0)
   */
  async predict(audioData) {
    if (!this.session) return 0.0;

    const inputTensor = new ort.Tensor('float32', audioData, [1, 512]);
    const stateTensor = new ort.Tensor('float32', this.state, [2, 1, 128]);
    const srTensor = new ort.Tensor('int64', BigInt64Array.from([16000n]), [1]);

    const results = await this.session.run({
      input: inputTensor,
      state: stateTensor,
      sr: srTensor
    });

    // Update state for next frame
    this.state = results.stateN.data;

    // Return speech probability
    return results.output.data[0];
  }

  /**
   * Reset LSTM state for a new conversation turn.
   */
  resetState() {
    this.state = new Float32Array(256);
  }
}

// Expose to global scope for Flutter dart:js_interop
window.SileroVADAdapter = SileroVADAdapter;
