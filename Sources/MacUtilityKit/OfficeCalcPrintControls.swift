import SwiftUI
import UtilityCore

struct OfficeCalcPrintControls: View {
    @Binding var options: OfficeCalcPrintOptions

    var body: some View {
        SettingRow("Sheets") {
            TextField("All or sheet numbers", text: $options.sheetRange)
                .textFieldStyle(.roundedBorder)
                .help("Numbered in workbook order, for example 1–3, 5.")
        }
        SettingRow("Cell range") {
            TextField("Saved print areas", text: $options.cellRange)
                .textFieldStyle(.roundedBorder)
                .help("Choose one sheet to print an area such as A1:F20.")
        }
        SettingRow("Paper") {
            Picker("Paper", selection: $options.paper) {
                Text("Workbook").tag(nil as PDFPrintPaper?)
                ForEach(PDFPrintPaper.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            .labelsHidden()
        }
        SettingRow("Orientation") {
            Picker("Orientation", selection: $options.orientation) {
                ForEach(OfficeCalcOrientation.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
        }
        Toggle("Fit to one page wide", isOn: $options.fitsOnePageWide)
    }
}
