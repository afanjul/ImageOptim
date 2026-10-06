//
//  SettingsView.swift
//  ImageOptim
//
//  Option A: Modern macOS HIG Settings with coherent semantics,
//  CPU Effort slider, unified formats catalog, and live benchmarks.
//

import ImageOptimGPL
import SwiftUI

struct SettingsView: View {
    var body: some View {
        ClassicTabView(tabs: [
            (String(localized: "Compresión", comment: "Preferences tab"), { AnyView(CompressionSettings()) }),
            (String(localized: "Formatos & Motores", comment: "Preferences tab"), { AnyView(FormatsEnginesSettings()) }),
            (String(localized: "Archivos & Metadatos", comment: "Preferences tab"), { AnyView(OutputFilesSettings()) }),
            (String(localized: "Rendimiento", comment: "Preferences tab"), { AnyView(PerformanceSettings()) }),
        ])
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20))
        .frame(width: 680, height: 445)
    }
}

/// The nib's `smallSystem`/`miniSystem` label fonts.
private extension Font {
    static let smallLabel = Font.system(size: NSFont.smallSystemFontSize)
    static let miniLabel = Font.system(size: NSFont.systemFontSize(for: .mini))
}

/// The hint lines under the checkboxes, indented to line up with the checkbox title.
private struct Hint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.smallLabel)
            .foregroundStyle(.secondary)
            .padding(.leading, 18)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Tab 1: Compresión (Modo, Esfuerzo de CPU y Calidad)

private struct CompressionSettings: View {
    @AppStorage(PrefKey.lossyEnabled) private var lossyEnabled = false
    @AppStorage(PrefKey.level) private var level = 4

    @AppStorage(PrefKey.jpegOptimMaxQuality) private var jpegQuality = 80
    @AppStorage(PrefKey.pngMinQuality) private var pngQuality = 60
    @AppStorage(PrefKey.gifQuality) private var gifQuality = 80
    @AppStorage(PrefKey.jpegOptimEnabled) private var jpegOptim = true
    @AppStorage(PrefKey.guetzliEnabled) private var guetzli = false
    @AppStorage(PrefKey.jpegTranStripAll) private var jpegTranStripAll = true
    @AppStorage(PrefKey.jpegTranStripAllSetByGuetzli) private var stripAllSetByGuetzli = false

    @State private var showsGuetzliWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. Selector de Fidelidad Visual (Lossless vs Lossy)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(String(localized: "Modo de fidelidad:", comment: "Preferences label"))
                        .font(.smallLabel.weight(.medium))
                        .frame(width: 140, alignment: .trailing)

                    Picker("", selection: $lossyEnabled) {
                        Text(String(localized: "🛡️ Sin pérdida (Lossless)", comment: "Mode option")).tag(false)
                        Text(String(localized: "✨ Optimización visual (Lossy)", comment: "Mode option")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                }

                HStack {
                    Spacer().frame(width: 148)
                    Text(lossyEnabled
                         ? String(localized: "Reduce hasta un 70% adicional descartando detalles imperceptibles al ojo humano.", comment: "Mode hint")
                         : String(localized: "Preserva cada píxel 100% idéntico al original. Compresión puramente matemática.", comment: "Mode hint"))
                        .font(.miniLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)

            Divider()

            // 2. Slider corregido de Esfuerzo de Procesador (CPU Effort)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(localized: "Esfuerzo de CPU:", comment: "Preferences slider"))
                            .font(.smallLabel.weight(.medium))
                        Text(String(localized: "Pasadas de compresión", comment: "Preferences sublabel"))
                            .font(.miniLabel)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 140, alignment: .trailing)
                    .padding(.top, 2)

                    VStack(spacing: 4) {
                        TickSlider(value: $level, range: 0...6, ticks: 7)
                            .frame(width: 320, height: 22)

                        HStack(spacing: 0) {
                            Text(String(localized: "⚡ Rápido", comment: "Slider tick"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(localized: "⚖️ Equilibrado", comment: "Slider tick"))
                                .frame(maxWidth: .infinity, alignment: .center)
                            Text(String(localized: "🔬 Profundo", comment: "Slider tick"))
                                .frame(maxWidth: .infinity, alignment: .center)
                            Text(String(localized: "🧬 Exhaustivo", comment: "Slider tick"))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.miniLabel.weight(.medium))
                        .frame(width: 320)
                    }

                    Spacer()
                }

                // Tarjeta explicativa dinámica según el nivel seleccionado
                HStack {
                    Spacer().frame(width: 148)
                    HStack(spacing: 8) {
                        LucideIcon(effortIcon, size: 14, color: effortColor)
                        Text(effortDescription)
                            .font(.miniLabel)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: 450, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            Divider()

            // 3. Calidad Visual (Sliders Lossy)
            GroupBox(String(localized: "Calidad Visual (Solo activa en modo Lossy)", comment: "Preferences group")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        sliderLabel(String(localized: "Calidad JPEG:", comment: "Preferences slider"))
                        QualitySlider(value: $jpegQuality, range: 50...99, ticks: 25,
                                      scale: ["50%", "75%", "99%"], isEnabled: lossyEnabled)
                        valueLabel(jpegQuality)
                    }
                    .disabled(!lossyEnabled || !jpegOptim)

                    HStack(alignment: .top, spacing: 16) {
                        HStack(alignment: .top, spacing: 8) {
                            sliderLabel(String(localized: "Calidad PNG:", comment: "Preferences slider"))
                            QualitySlider(value: $pngQuality, range: 40...100, ticks: 7,
                                          scale: ["40%", "70%", "100%"], isEnabled: lossyEnabled)
                            valueLabel(pngQuality)
                        }
                        HStack(alignment: .top, spacing: 8) {
                            sliderLabel(String(localized: "Calidad GIF:", comment: "Preferences slider"))
                            QualitySlider(value: $gifQuality, range: 40...100, ticks: 7,
                                          scale: ["40%", "70%", "100%"], isEnabled: lossyEnabled)
                            valueLabel(gifQuality)
                        }
                    }
                    .disabled(!lossyEnabled)
                }
                .padding(6)
            }

            Spacer(minLength: 4)

            HStack {
                Spacer()
                HelpButton(anchor: "general")
            }
        }
        .onChange(of: guetzli) { _, isEnabled in
            guetzliChanged(isEnabled)
        }
        .alert(String(localized: "Guetzli is very slow", comment: "alert box"), isPresented: $showsGuetzliWarning) {
            Button(String(localized: "OK", comment: "alert box")) {}
        } message: {
            Text(String(localized: "It can take up to 30 minutes per image. Your system may be unresponsive while Guetzli is running.",
                        comment: "alert box"))
        }
    }

    private var effortIcon: LucideIconName {
        switch level {
        case 0...1: return .zap
        case 2...4: return .sparkles
        case 5: return .gauge
        default: return .cpu
        }
    }

    private var effortColor: Color {
        switch level {
        case 0...1: return .yellow
        case 2...4: return .accentColor
        case 5: return .purple
        default: return .red
        }
    }

    private var effortDescription: String {
        switch level {
        case 0...1:
            return String(localized: "⚡ 1 pase ultrarrápido (milisegundos). Máxima velocidad, ideal para miles de fotos.", comment: "Effort hint")
        case 2...4:
            return String(localized: "⚖️ Equilibrado (Recomendado): Compromiso óptimo diario entre reducción de bytes y uso de CPU.", comment: "Effort hint")
        case 5:
            return String(localized: "🔬 Compresión profunda: Múltiples iteraciones de Zopfli y MozJPEG. Ahorro de bytes adicional en segundos.", comment: "Effort hint")
        default:
            return String(localized: "🧬 Exhaustivo (Fuerza bruta): Hasta 21 iteraciones Zopfli para el menor peso posible. Intensivo en procesador.", comment: "Effort hint")
        }
    }

    private func sliderLabel(_ title: String) -> some View {
        Text(title)
            .font(.smallLabel)
            .foregroundStyle(lossyEnabled ? Color(nsColor: .controlTextColor) : Color(nsColor: .disabledControlTextColor))
            .frame(width: 95, alignment: .trailing)
            .padding(.top, 3)
    }

    private func valueLabel(_ value: Int) -> some View {
        Text(verbatim: "\(value)%")
            .font(.miniLabel)
            .monospacedDigit()
            .foregroundStyle(lossyEnabled ? Color(nsColor: .controlTextColor) : Color(nsColor: .disabledControlTextColor))
            .frame(width: 34, alignment: .leading)
            .padding(.top, 6)
    }

    private func guetzliChanged(_ isEnabled: Bool) {
        if isEnabled {
            if !NodeTools.warnedAboutGuetzli {
                NodeTools.warnedAboutGuetzli = true
                showsGuetzliWarning = true
            }
            if jpegQuality < 85 {
                jpegQuality = 85
            }
            if !jpegTranStripAll {
                stripAllSetByGuetzli = true
                jpegTranStripAll = true
            }
        } else if jpegTranStripAll, stripAllSetByGuetzli {
            stripAllSetByGuetzli = false
            jpegTranStripAll = false
        }
    }
}

// MARK: - Tab 2: Formatos & Motores

private struct FormatsEnginesSettings: View {
    @AppStorage(PrefKey.zopfliEnabled) private var zopfli = true
    @AppStorage(PrefKey.oxiPngEnabled) private var oxiPng = true
    @AppStorage(PrefKey.advPngEnabled) private var advPng = true
    @AppStorage(PrefKey.pngCrushEnabled) private var pngCrush = true

    @AppStorage(PrefKey.jpegOptimEnabled) private var jpegOptim = true
    @AppStorage(PrefKey.jpegTranEnabled) private var jpegTran = true
    @AppStorage(PrefKey.guetzliEnabled) private var guetzli = false

    @AppStorage(PrefKey.webpEnabled) private var webp = true
    @AppStorage(PrefKey.avifEnabled) private var avif = true
    @AppStorage(PrefKey.jxlEnabled) private var jxl = true
    @AppStorage(PrefKey.heicToJpegEnabled) private var heicToJpeg = true

    @AppStorage(PrefKey.gifsicleEnabled) private var gifsicle = true
    @AppStorage(PrefKey.svgoEnabled) private var svgo = false
    @AppStorage(PrefKey.svgCleanerEnabled) private var svgCleaner = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                // Columna 1: PNG y Vectores
                VStack(spacing: 10) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                FormatBadge(format: "PNG")
                                Text("PNG (Compresión sin pérdida)")
                                    .font(.smallLabel.bold())
                            }
                            .padding(.bottom, 2)

                            Toggle("Zopfli", isOn: $zopfli)
                                .help(String(localized: "Google's exhaustive DEFLATE algorithm (highest compression)", comment: "tooltip"))
                            Toggle("OxiPNG", isOn: $oxiPng)
                                .help(String(localized: "High-performance multi-threaded lossless optimizer (Rust)", comment: "tooltip"))
                            Toggle("AdvPNG", isOn: $advPng)
                                .help(String(localized: "AdvanceCOMP 7z DEFLATE recompression", comment: "tooltip"))
                            Toggle("PNGCrush", isOn: $pngCrush)
                                .help(String(localized: "PNG filter optimization and chunk reduction", comment: "tooltip"))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                FormatBadge(format: "SVG")
                                FormatBadge(format: "GIF")
                                Text("SVG & GIF (Vector & Animado)")
                                    .font(.smallLabel.bold())
                            }
                            .padding(.bottom, 2)

                            Toggle("SVGO", isOn: $svgo)
                                .help(String(localized: "Scalable Vector Graphics Node.js optimizer", comment: "tooltip"))
                            Toggle("SVG Cleaner", isOn: $svgCleaner)
                                .help(String(localized: "Fast SVG syntactic cleaner written in Rust", comment: "tooltip"))
                            Toggle("Gifsicle", isOn: $gifsicle)
                                .help(String(localized: "GIF frame optimization and palette reduction", comment: "tooltip"))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Columna 2: JPEG y Formatos Modernos
                VStack(spacing: 10) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                FormatBadge(format: "JPEG")
                                Text("JPEG")
                                    .font(.smallLabel.bold())
                            }
                            .padding(.bottom, 2)

                            Toggle("JPEGOptim", isOn: $jpegOptim)
                                .help(String(localized: "Huffman table optimization and lossy quality caps", comment: "tooltip"))
                            Toggle("Jpegtran", isOn: $jpegTran)
                                .help(String(localized: "Lossless Huffman optimization and scan reordering", comment: "tooltip"))
                            Toggle("Guetzli", isOn: $guetzli)
                                .help(String(localized: "Google Butteraugli perceptual encoder (very CPU intensive)", comment: "tooltip"))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                FormatBadge(format: "WebP")
                                FormatBadge(format: "AVIF")
                                FormatBadge(format: "JXL")
                                Text("Formatos Web Modernos")
                                    .font(.smallLabel.bold())
                            }
                            .padding(.bottom, 2)

                            Toggle("WebP (cwebp)", isOn: $webp)
                                .help(String(localized: "Google WebP image optimizer", comment: "tooltip"))
                            Toggle("AVIF (avifoptim)", isOn: $avif)
                                .help(String(localized: "Next-gen AV1 format compression", comment: "tooltip"))
                            Toggle("JPEG XL (jxloptim)", isOn: $jxl)
                                .help(String(localized: "Next-gen JPEG XL lossy/lossless optimizer", comment: "tooltip"))
                            Toggle("HEIC a JPEG", isOn: $heicToJpeg)
                                .help(String(localized: "Auto-convert Apple HEIC photos to compatible JPEG", comment: "tooltip"))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Spacer(minLength: 4)

            HStack {
                Spacer()
                HelpButton(anchor: "general")
            }
        }
    }
}

// MARK: - Tab 3: Archivos & Metadatos

private struct OutputFilesSettings: View {
    @AppStorage(PrefKey.preserveOriginal) private var preserveOriginal = false
    @AppStorage(PrefKey.outputFolderPath) private var outputFolderPath = ""
    @AppStorage(PrefKey.filenamePrefix) private var filenamePrefix = ""
    @AppStorage(PrefKey.filenameSuffix) private var filenameSuffix = ""

    @AppStorage(PrefKey.removePngChunks) private var removePngChunks = true
    @AppStorage(PrefKey.jpegTranStripAll) private var jpegTranStripAll = true
    @AppStorage(PrefKey.preserveDates) private var preserveDates = false
    @AppStorage(PrefKey.preservePermissions) private var preservePermissions = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // Destino y Nombres
                GroupBox(String(localized: "Destino y Copias de Seguridad", comment: "Preferences group")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(String(localized: "Preservar originales (guardar como copia)", comment: "Preferences checkbox"),
                               isOn: $preserveOriginal)
                        Hint(String(localized: "Nunca sobreescribe el archivo de entrada original", comment: "Preferences hint"))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "Carpeta de salida:", comment: "Preferences label"))
                                .font(.smallLabel.weight(.medium))
                            HStack {
                                TextField(String(localized: "Misma que el original", comment: "Placeholder"), text: $outputFolderPath)
                                    .textFieldStyle(.roundedBorder)
                                Button(String(localized: "Elegir…", comment: "Button")) {
                                    selectOutputFolder()
                                }
                                if !outputFolderPath.isEmpty {
                                    Button(String(localized: "Restablecer", comment: "Button")) {
                                        outputFolderPath = ""
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "Plantilla de nombre:", comment: "Preferences label"))
                                .font(.smallLabel.weight(.medium))
                            HStack {
                                TextField(String(localized: "Prefijo", comment: "Placeholder"), text: $filenamePrefix)
                                    .textFieldStyle(.roundedBorder)
                                Text("+ [nombre] +")
                                    .font(.smallLabel)
                                    .foregroundStyle(.secondary)
                                TextField(String(localized: "Sufijo", comment: "Placeholder"), text: $filenameSuffix)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Hint(String(localized: "Tokens compatibles: {date}. Ejemplo: \(previewFilename)", comment: "Preferences hint"))
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Metadatos y Privacidad
                GroupBox(String(localized: "Metadatos y Privacidad", comment: "Preferences group")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(String(localized: "Eliminar metadatos PNG", comment: "Preferences checkbox"),
                               isOn: $removePngChunks)
                        Hint(String(localized: "Elimina fragmentos tEXt, iTXt, zTXt (comentarios, perfiles y metadatos innecesarios)", comment: "Preferences hint"))

                        Toggle(String(localized: "Eliminar EXIF, perfiles de color y GPS de JPEG", comment: "Preferences checkbox"),
                               isOn: $jpegTranStripAll)
                        Hint(String(localized: "Protege tu privacidad eliminando ubicación y datos de captura", comment: "Preferences hint"))

                        Divider().padding(.vertical, 2)

                        Toggle(String(localized: "Preservar fecha y hora original del archivo", comment: "Preferences checkbox"),
                               isOn: $preserveDates)
                        Hint(String(localized: "Mantiene la fecha de modificación original sin cambios", comment: "Preferences hint"))

                        Toggle(String(localized: "Preservar permisos originales del archivo", comment: "Preferences checkbox"),
                               isOn: $preservePermissions)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 4)

            HStack {
                Spacer()
                HelpButton(anchor: "general")
            }
        }
    }

    private var previewFilename: String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: now)
        let p = filenamePrefix.replacingOccurrences(of: "{date}", with: dateStr)
        let s = filenameSuffix.replacingOccurrences(of: "{date}", with: dateStr)
        return "\(p)foto\(s).jpg"
    }

    private func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            outputFolderPath = url.path
        }
    }
}

// MARK: - Tab 4: Rendimiento & Benchmarks

private struct PerformanceSettings: View {
    @State private var tracker = BenchmarkTracker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tarjeta de Apple Silicon P-cores
            HStack(spacing: 12) {
                LucideIcon(.cpu, size: 28, color: .purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Aceleración de hardware Apple Silicon", comment: "Hardware info title"))
                        .font(.smallLabel.bold())
                    Text(String(localized: "ImageOptim despacha las tareas de compresión en paralelo con calidad de servicio .userInitiated, asignando automáticamente todos los núcleos de alto rendimiento (P-cores) para máxima velocidad.", comment: "Hardware info detail"))
                        .font(.miniLabel)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            // Tabla de Benchmarks
            GroupBox(String(localized: "Benchmarks en Vivo de Motores (Tiempos de Ejecución)", comment: "Preferences group")) {
                VStack(alignment: .leading, spacing: 6) {
                    let benchmarks = tracker.allBenchmarksSorted

                    if benchmarks.isEmpty {
                        VStack(spacing: 6) {
                            LucideIcon(.gauge, size: 24, color: .secondary)
                            Text(String(localized: "No hay mediciones de motores registradas todavía.", comment: "Preferences hint"))
                                .font(.smallLabel.bold())
                            Text(String(localized: "Arrastra y optimiza imágenes para ver mediciones en vivo, promedios históricos y categorías de velocidad por motor.", comment: "Preferences hint"))
                                .font(.miniLabel)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else {
                        VStack(spacing: 0) {
                            HStack {
                                Text(String(localized: "Motor", comment: "Table header")).bold().frame(width: 90, alignment: .leading)
                                Text(String(localized: "Formato", comment: "Table header")).bold().frame(width: 50, alignment: .center)
                                Text(String(localized: "Promedio", comment: "Table header")).bold().frame(width: 70, alignment: .trailing)
                                Text(String(localized: "Última", comment: "Table header")).bold().frame(width: 70, alignment: .trailing)
                                Text(String(localized: "Pasadas", comment: "Table header")).bold().frame(width: 50, alignment: .trailing)
                                Text(String(localized: "Velocidad", comment: "Table header")).bold().frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .font(.miniLabel)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)

                            Divider()

                            ScrollView {
                                VStack(spacing: 4) {
                                    ForEach(benchmarks) { stat in
                                        HStack {
                                            Text(stat.engineName)
                                                .font(.smallLabel.weight(.medium))
                                                .frame(width: 90, alignment: .leading)

                                            FormatBadge(format: stat.formatName)
                                                .frame(width: 50, alignment: .center)

                                            Text(stat.formattedAverageDuration)
                                                .font(.smallLabel.monospacedDigit())
                                                .frame(width: 70, alignment: .trailing)

                                            Text(stat.formattedLastDuration)
                                                .font(.smallLabel.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .frame(width: 70, alignment: .trailing)

                                            Text("\(stat.runsCount)")
                                                .font(.smallLabel.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .frame(width: 50, alignment: .trailing)

                                            Text(stat.speedCategory)
                                                .font(.miniLabel.bold())
                                                .frame(maxWidth: .infinity, alignment: .trailing)
                                        }
                                        .padding(.vertical, 1)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .frame(maxHeight: 120)

                            Divider()

                            HStack {
                                Button {
                                    tracker.reset()
                                } label: {
                                    HStack(spacing: 4) {
                                        LucideIcon(.trash2, size: 11)
                                        Text(String(localized: "Restablecer estadísticas", comment: "Button"))
                                    }
                                }
                                .controlSize(.small)

                                Spacer()

                                Text("\(benchmarks.count) motores evaluados")
                                    .font(.miniLabel)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(6)
            }

            Spacer(minLength: 4)

            HStack {
                Spacer()
                HelpButton(anchor: "optipng")
            }
        }
    }
}

// MARK: - Quality Slider Helper

private struct QualitySlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let ticks: Int
    let scale: [String]
    let isEnabled: Bool

    var body: some View {
        VStack(spacing: 5) {
            TickSlider(value: $value, range: range, ticks: ticks)
                .frame(height: 22)
            HStack(spacing: 0) {
                Text(scale[0])
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(scale[1])
                    .frame(maxWidth: .infinity, alignment: .center)
                Text(scale[2])
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.miniLabel)
            .foregroundStyle(isEnabled ? Color(nsColor: .controlTextColor) : Color(nsColor: .disabledControlTextColor))
        }
    }
}

// MARK: - AppKit Controls

private struct ClassicTabView: NSViewRepresentable {
    let tabs: [(title: String, content: () -> AnyView)]

    @MainActor
    final class Coordinator: NSObject, NSTabViewDelegate {
        var pages: [() -> AnyView] = []

        func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
            guard let tabViewItem,
                  let index = tabView.tabViewItems.firstIndex(of: tabViewItem)
            else { return }
            host(page: index, in: tabViewItem)
        }

        func host(page index: Int, in item: NSTabViewItem) {
            guard pages.indices.contains(index),
                  let container = item.view, container.subviews.isEmpty
            else { return }

            let hosting = NSHostingView(rootView: pages[index]())
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTabView {
        let tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        context.coordinator.pages = tabs.map(\.content)
        tabView.delegate = context.coordinator

        for tab in tabs {
            let item = NSTabViewItem(identifier: tab.title)
            item.label = tab.title
            item.view = NSView()
            tabView.addTabViewItem(item)
        }

        if let first = tabView.tabViewItems.first {
            context.coordinator.host(page: 0, in: first)
        }
        return tabView
    }

    func updateNSView(_ tabView: NSTabView, context: Context) {
        context.coordinator.pages = tabs.map(\.content)
        for (item, tab) in zip(tabView.tabViewItems, tabs) where item.label != tab.title {
            item.label = tab.title
        }
    }
}

private struct TickSlider: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let ticks: Int

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(value),
                              minValue: Double(range.lowerBound),
                              maxValue: Double(range.upperBound),
                              target: context.coordinator,
                              action: #selector(Coordinator.sliderMoved(_:)))
        slider.numberOfTickMarks = ticks
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        if Int(slider.doubleValue.rounded()) != value {
            slider.doubleValue = Double(value)
        }
        slider.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 22)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Int>

        init(value: Binding<Int>) {
            self.value = value
        }

        @objc func sliderMoved(_ sender: NSSlider) {
            let rounded = Int(sender.doubleValue.rounded())
            if value.wrappedValue != rounded {
                value.wrappedValue = rounded
            }
        }
    }
}

private struct HelpButton: NSViewRepresentable {
    let anchor: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.pressed))
        button.bezelStyle = .helpButton
        button.toolTip = String(localized: "ImageOptim Help", comment: "Menu Item")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.anchor = anchor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(anchor: anchor)
    }

    @MainActor
    final class Coordinator: NSObject {
        var anchor: String

        init(anchor: String) {
            self.anchor = anchor
        }

        @objc func pressed() {
            Help.show(anchor: anchor)
        }
    }
}

enum NodeTools {
    static var svgSupported: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: "/usr/local/bin/node") || fm.isExecutableFile(atPath: "/opt/homebrew/bin/node")
    }

    @MainActor static var warnedAboutGuetzli = false
}
