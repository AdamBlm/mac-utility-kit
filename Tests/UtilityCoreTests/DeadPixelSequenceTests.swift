import Testing
import UtilityCore

@Test func deadPixelSequenceStepsAndWrapsInBothDirections() {
    var sequence = DeadPixelSequence()
    #expect(sequence.color == .black)
    for expected: DeadPixelColor in [.white, .red, .green, .blue, .black] {
        sequence.step(1)
        #expect(sequence.color == expected)
    }
    sequence.step(-1)
    #expect(sequence.color == .blue)
    sequence.step(2)
    #expect(sequence.color == .white)
}
