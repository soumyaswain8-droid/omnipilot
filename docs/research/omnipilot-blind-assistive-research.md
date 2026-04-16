# OmniPilot: AI Assistive Vision for the Blind

*Research Document -- April 2026*

---

## 1. Existing Products Landscape

### Hardware Devices

| Product | Type | Key Features | Price (USD) | India Available | Language Support |
|---------|------|-------------|-------------|-----------------|-----------------|
| **OrCam MyEye 3 Pro** | Clip-on camera for glasses | Text reading, face recognition, product ID, AI assistant, 20+ languages | $4,250 | Yes (Amazon.in, Ubuy) | English + limited Hindi |
| **Envision Glasses** | Smart glasses (Google Glass) | Scene description, OCR, face recognition, video calling to sighted helper | $3,500 | Import only | English-centric |
| **WeWalk Smart Cane 2** | Smart cane handle | Ultrasonic obstacle detection (head height), GPS navigation, GPT voice assistant, 20hr battery | $850-1,150 | Not officially | English |
| **Seekr (Vidi Labs)** | Clip-on wearable camera | Depth-sensing camera, scene description, Bluetooth earpiece | $700 | No | English |

### Software / App-Based Solutions

| Product | Platform | Key Features | Cost | India Available |
|---------|----------|-------------|------|-----------------|
| **Be My Eyes + Be My AI** | iOS, Android | GPT-4 powered visual Q&A, 700K users, 8M volunteers | Free | Yes |
| **Microsoft Seeing AI** | iOS, Android | Text/document reading, currency ID, scene description, people detection | Free | Yes (limited Indian currency) |
| **Aira** | iOS, Android | Live human agents + Google DeepMind Astra AI for real-time guidance | Subscription ($30-100/mo) | No (US/UK focused) |
| **Google Lookout** | Android | Text reading, food labels, scene description, currency | Free | Yes (limited) |
| **RBI MANI App** | iOS, Android | Indian banknote identification (Rs 10-2000), works offline | Free | Yes (India-specific) |

### Key Observations

1. **Price barrier is massive.** OrCam at $4,250 (Rs 3.5L+) and Envision at $3,500 are unaffordable for 80% of India's blind population.
2. **No product nails Indian languages.** Hindi/regional OCR, TTS, and scene description remain a gap.
3. **App-based solutions are free but phone-dependent.** A blind person must locate, orient, and hold their phone camera -- not always practical.
4. **WeWalk solves navigation but not vision.** No camera, no scene understanding.
5. **No product combines always-on vision + navigation + voice assistant in an affordable package.**

---

## 2. India Market Opportunity

### Population & Need

| Metric | Number | Source |
|--------|--------|--------|
| Totally blind | 5-8 million | WHO / NPCBVI estimates |
| Visually impaired (moderate to severe) | 60-70 million | Lancet Global Health |
| Children blind | 240,000+ | NPCBVI |
| Blindness prevalence | ~0.36% (vs 0.2% global avg) | Census + surveys |
| Socioeconomic: low/middle income | ~80% of blind population | IHOPE Journal |

### Affordability Reality

- Average monthly income of target users: Rs 5,000-15,000
- ADIP scheme covers devices up to Rs 15,000 free; 50% subsidy for Rs 15K-30K
- **Sweet spot for device pricing: Rs 5,000-15,000** (fully covered by ADIP)
- At Rs 25,000-30,000, government covers 50% -- user pays Rs 12,500-15,000
- Anything above Rs 30,000 requires case-by-case approval (20% of ADIP budget)

### Government Schemes

| Scheme | Coverage | Max Amount |
|--------|----------|------------|
| **ADIP (Dept of Empowerment of PwD)** | Free aids/appliances for disability >40%, income <Rs 30K/mo | Rs 15,000 (100%), Rs 30,000 (50%) |
| **NHFDC Loans** | Concessional loans for assistive devices | Up to Rs 10 lakh |
| **State disability welfare** | Varies by state -- Maharashtra, Tamil Nadu, Karnataka have active programs | Varies |
| **RPWD Act 2016** | Central govt employees entitled to assistive devices | Employer-funded |

### The Language Gap (Critical Differentiator)

India has 22 official languages. Current assistive tech landscape:

- **English**: Well-served by all products
- **Hindi**: NVDA screen reader works, OCR accuracy ~70-80%, TTS available but robotic
- **Tamil, Telugu, Kannada, Bengali, Marathi**: OCR accuracy drops to 50-65%, TTS quality poor
- **Scene description in Indian languages**: Virtually non-existent in any product
- **Voice command in Hindi**: Google Assistant works; no assistive device supports it natively

**A device that speaks Hindi fluently while describing the world = massive unmet need.**

---

## 3. Technology Stack for Building OmniPilot Vision

### Hardware (Pendant Form Factor)

| Component | Options | Est. Cost |
|-----------|---------|-----------|
| Processor | Raspberry Pi Zero 2W / ESP32-S3 / Qualcomm QCS6490 | $15-80 |
| Camera | OV5647 (5MP) / IMX219 (8MP) / Wide-angle with depth | $5-25 |
| Microphone | MEMS mic array (2-4 mics for noise cancellation) | $2-5 |
| Speaker/haptic | Bone conduction transducer or Bluetooth to earpiece | $5-15 |
| GPS + compass | u-blox NEO-M8N + magnetometer | $10-15 |
| Battery | 1000-2000mAh LiPo (4-8hr runtime) | $3-8 |
| Connectivity | WiFi + BLE (ESP32) or 4G LTE module | $5-20 |
| Enclosure | 3D printed pendant, ~40g target | $2-5 |
| **Total BOM** | | **$50-175** |

At scale (10K units), target BOM: **$60-80 = Rs 5,000-6,500**

### Software Stack

#### On-Device (Latency-Critical)

| Capability | Model/Tool | Framework | Latency Target |
|------------|-----------|-----------|----------------|
| Object detection | YOLOv8n / YOLOv10n | TFLite / ONNX Runtime | <100ms |
| Face detection | BlazeFace / MobileFaceNet | TFLite | <50ms |
| Face recognition | ArcFace-MobileNet | TFLite | <100ms |
| OCR (English) | PaddleOCR-Mobile / Tesseract | On-device | <200ms |
| OCR (Hindi/regional) | PaddleOCR (Devanagari model) / Google MLKit | On-device | <300ms |
| Currency detection | Custom YOLOv8 (trained on Indian notes) | TFLite | <100ms |
| Obstacle proximity | Monocular depth estimation (MiDaS-small) | TFLite | <150ms |
| Wake word | Porcupine (Picovoice) | On-device | Always-on |

#### Cloud (Rich Understanding)

| Capability | API/Model | When Used |
|------------|----------|-----------|
| Scene description | GPT-4o / Claude / Gemini multimodal | On voice query or periodic scan |
| Complex Q&A about surroundings | LLM with image input | User asks "what's in front of me?" |
| Navigation | Google Maps / Mapbox Directions API | Route planning |
| Hindi/regional TTS | Google Cloud TTS / Azure TTS (Neural) | All voice output |
| Hindi/regional STT | Whisper / Google STT | Voice input |

#### Open-Source Tools (Ready to Use)

| Tool | Purpose | License |
|------|---------|---------|
| **YOLOv8/v10** (Ultralytics) | Object detection, custom training | AGPL-3.0 |
| **MobileNet v3** | Lightweight classification | Apache 2.0 |
| **PaddleOCR** | Multi-language OCR including Hindi | Apache 2.0 |
| **MiDaS** | Monocular depth estimation | MIT |
| **Whisper** (OpenAI) | Speech-to-text (Hindi support) | MIT |
| **Piper TTS** | Offline neural TTS (Hindi voices available) | MIT |
| **Picovoice Porcupine** | Wake word detection | Apache 2.0 (free tier) |
| **Apple Vision Framework** | iOS: text recognition, face detection, scene classification | iOS only |
| **Google ML Kit** | Android: OCR, face detection, object detection | Android/iOS |
| **OpenCV** | Image processing, camera pipeline | Apache 2.0 |

---

## 4. OmniPilot for Blind Users: Product Concept

### Form Factor: Camera Pendant (Like Omi, But Sees)

A lightweight pendant (~40-50g) worn around the neck or clipped to clothing:
- Wide-angle camera (120-degree FoV) pointing forward
- 2 MEMS microphones for voice commands + ambient awareness
- Bone conduction speaker (ears remain open for safety)
- Haptic motor for obstacle alerts
- 6-8 hour battery
- Pairs with phone via BLE for cloud features, but core features work offline

### Core Use Cases (Priority Order)

| # | Use Case | Tech Required | Online/Offline |
|---|----------|--------------|----------------|
| 1 | **Obstacle alert** | Depth estimation + haptic | Offline |
| 2 | **Currency identification** | Custom YOLO model (Indian notes) | Offline |
| 3 | **Text reading** (signs, labels, menus) | OCR + TTS | Offline |
| 4 | **Scene description** ("What's around me?") | LLM multimodal | Online |
| 5 | **Face recognition** ("Who is this?") | ArcFace + local DB | Offline |
| 6 | **Navigation** ("Take me to nearest bus stop") | GPS + Maps API | Online |
| 7 | **Voice Q&A** ("What color is this shirt?") | LLM multimodal | Online |
| 8 | **Document reading** (letters, forms) | OCR + TTS | Offline |
| 9 | **Product identification** (barcode/QR scan) | ZXing/ML Kit | Offline |
| 10 | **Emergency help** (fall detection + SOS) | Accelerometer + phone call | Online |

### What Makes This Different from Existing Products

| Dimension | OrCam ($4,250) | Envision ($3,500) | WeWalk ($850) | OmniPilot (Target) |
|-----------|---------------|-------------------|--------------|-------------------|
| Price | Rs 3.5L+ | Rs 2.9L+ | Rs 70K+ | **Rs 5,000-15,000** |
| Always-on vision | No (button press) | No (gesture) | No camera | **Yes (continuous)** |
| Hindi scene description | No | No | No | **Yes** |
| Navigation | No | No | Yes (voice) | **Yes (voice + haptic)** |
| Currency (Indian) | Limited | No | No | **Yes (all denominations)** |
| ADIP scheme eligible | No (too expensive) | No | Borderline | **Yes (under Rs 15K)** |
| Offline core features | Yes | Partial | Yes | **Yes** |
| Form factor | Glasses clip | Smart glasses | Cane handle | **Pendant/clip** |

### Pricing Strategy for India

| Tier | Price | Features | Target |
|------|-------|----------|--------|
| **OmniPilot Lite** | Rs 4,999 | Obstacle alert + currency ID + basic OCR (offline only) | ADIP scheme (100% covered) |
| **OmniPilot Standard** | Rs 12,999 | All offline + cloud scene description + navigation | ADIP scheme (100% covered) |
| **OmniPilot Pro** | Rs 24,999 | Everything + face recognition + continuous narration | ADIP 50% subsidy (user pays ~Rs 12.5K) |

Cloud features: Rs 99/month or Rs 999/year (subsidized by NGO partnerships).

---

## 5. Build Roadmap

### Phase 1: Software MVP (Months 1-3)
- Phone app (Android) with camera + all AI features
- Validate: OCR accuracy in Hindi, scene description quality, currency detection
- Test with 10-20 blind users in Bangalore/Hyderabad
- Cost: Rs 0 (phone they already own)

### Phase 2: Pendant Prototype (Months 4-6)
- Raspberry Pi Zero 2W + camera module + BLE
- 3D printed enclosure, ~50g
- Pairs with phone app for cloud features
- Test with 50 users across 3 cities
- Cost: ~Rs 3,000 per prototype

### Phase 3: Custom Hardware (Months 7-12)
- Custom PCB (ESP32-S3 or Qualcomm QCS4490)
- Injection-molded enclosure
- Bone conduction audio
- Target: Rs 5,000 BOM at 1,000-unit run
- ADIP scheme certification

### Phase 4: Scale (Year 2)
- Partner with NIVH (National Institute for Visually Handicapped)
- NGO distribution (NAB India, Sightsavers, LV Prasad Eye Institute)
- State disability welfare department integration
- Target: 10,000 devices in Year 2

---

## 6. Key Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Hindi OCR accuracy below 80% | High | PaddleOCR fine-tuning on Indian signage dataset |
| Battery life under 4 hours | Medium | Aggressive duty cycling; camera on-demand vs always-on |
| Cloud latency for scene description | Medium | Edge LLM (Phi-3-mini) for basic descriptions; cloud for detailed |
| ADIP scheme approval delays | Medium | Start with NGO distribution channel |
| User adoption (device stigma) | Medium | Pendant form factor is discreet; looks like a fashion accessory |
| Heat in Indian climate (40C+) | Low | Thermal throttling; passive cooling design |

---

## 7. Summary

**The opportunity**: 60M+ visually impaired Indians have zero access to AI-powered assistive vision. Every existing product is either too expensive (OrCam at Rs 3.5L), English-only, or lacks a camera.

**The gap**: No product under Rs 15,000 combines always-on camera + Hindi scene description + navigation + currency ID. The ADIP scheme creates a government-funded distribution channel for devices under Rs 15K.

**The tech is ready**: YOLOv8, PaddleOCR, Whisper, multimodal LLMs, and edge AI processors make this buildable today. The missing piece is a product team that packages it for Indian users in Indian languages at Indian price points.

**OmniPilot's advantage**: Already building an always-listening AI companion. Adding vision (camera) to the existing audio platform creates the first affordable AI eyes for blind Indians.

---

*Sources: OrCam, Envision, WeWalk, Be My Eyes, Microsoft Seeing AI, RBI MANI, WHO, NPCBVI, ADIP Scheme (DEPwD), Ultralytics, PaddleOCR, Google ML Kit, Apple Vision Framework*
