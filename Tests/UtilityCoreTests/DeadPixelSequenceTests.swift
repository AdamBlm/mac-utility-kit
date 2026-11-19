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

@Test func deadPixelSequenceStartsAtChosenColorAndJumpsByNumber() {
    var sequence = DeadPixelSequence(startingAt: .red)
    #expect(sequence.color == .red)
    let selectedBlue = sequence.select(number: 5)
    #expect(selectedBlue)
    #expect(sequence.color == .blue)
    sequence.step(1)
    #expect(sequence.color == .black)
    let selectedWhite = sequence.select(number: 2)
    #expect(selectedWhite)
    #expect(sequence.color == .white)
    let selectedNegative = sequence.select(number: Int.min)
    #expect(!selectedNegative)
    let selectedAboveRange = sequence.select(number: 6)
    #expect(!selectedAboveRange)
    #expect(sequence.color == .white)
}
