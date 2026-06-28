import Foundation

/// ライセンス1件分（表示用）。`text` は原文（英語のまま）。`role` は用途説明（日本語化対象）。
struct LicenseItem: Identifiable {
    var id: String { name }
    let name: String
    let role: String
    let license: String
    let url: String?
    let text: String
}

/// カテゴリ単位のグループ。
struct LicenseSection: Identifiable {
    var id: String { title }
    let title: String
    let footer: String?
    let items: [LicenseItem]
}

// MARK: - License body templates（標準ライセンスはテンプレートで正確に生成）

func mitLicenseText(_ copyright: String) -> String {
    """
    MIT License

    \(copyright)

    Permission is hereby granted, free of charge, to any person obtaining a copy \
    of this software and associated documentation files (the "Software"), to deal \
    in the Software without restriction, including without limitation the rights \
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
    copies of the Software, and to permit persons to whom the Software is \
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all \
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
    SOFTWARE.
    """
}

func bsd3LicenseText(_ copyright: String) -> String {
    """
    BSD 3-Clause License

    \(copyright)
    All rights reserved.

    Redistribution and use in source and binary forms, with or without \
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this \
       list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright notice, \
       this list of conditions and the following disclaimer in the documentation \
       and/or other materials provided with the distribution.
    3. Neither the name of the copyright holder nor the names of its contributors \
       may be used to endorse or promote products derived from this software \
       without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND \
    ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED \
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE \
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE \
    FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL \
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR \
    SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER \
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, \
    OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE \
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """
}

// MARK: - 非テンプレ（Apple/PyTorch/Pillow）— 正確な全文は upstream を案内

let appleMobileCLIPNotice = """
MobileCLIP — © Apple Inc.

This app can bundle a Core ML model converted from Apple's MobileCLIP-S2. In the
apple/ml-mobileclip repository the licenses are split:

  • Code: MIT License (LICENSE)
  • Pretrained model weights: Apple Machine Learning Research Model License
    (LICENSE_MODELS) — permitted for Research Purposes only. Commercial
    exploitation, product development, and use in any commercial product or
    service are NOT permitted. Redistribution requires providing a copy of that
    agreement to the recipient.
  • Training data: CC-BY-NC-ND 4.0 (LICENSE_DATA; not distributed with this app).

The model is generated locally (scripts/build_mobileclip.sh) and is not included in
the source repository. See the repository for the full, authoritative license texts.

https://github.com/apple/ml-mobileclip
"""

let pillowLicenseText = """
The Python Imaging Library (PIL) is

    Copyright © 1997-2011 by Secret Labs AB
    Copyright © 1995-2011 by Fredrik Lundh and contributors

Pillow is the friendly PIL fork. It is

    Copyright © 2010 by Jeffrey A. Clark and contributors

Like PIL, Pillow is licensed under the open source HPND License:

By obtaining, using, and/or copying this software and/or its associated \
documentation, you agree that you have read, understood, and will comply with the \
following terms and conditions:

Permission to use, copy, modify and distribute this software and its documentation \
for any purpose and without fee is hereby granted, provided that the above \
copyright notice appears in all copies, and that both that copyright notice and \
this permission notice appear in supporting documentation, and that the name of \
Secret Labs AB or the author not be used in advertising or publicity pertaining to \
distribution of the software without specific, written prior permission.

SECRET LABS AB AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS \
SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO \
EVENT SHALL SECRET LABS AB OR THE AUTHOR BE LIABLE FOR ANY SPECIAL, INDIRECT OR \
CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA \
OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, \
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
"""

let pytorchLicenseText = """
PyTorch is BSD 3-Clause licensed.

Copyright (c) 2016- Facebook, Inc (Adam Paszke, Soumith Chintala and others) and
the PyTorch contributors. All rights reserved.

PyTorch carries an extensive copyright notice covering many contributors. The full,
authoritative license and notice are available at:

https://github.com/pytorch/pytorch/blob/main/LICENSE
"""

let appleFrameworksNotice = """
Apple SDKs & SF Symbols — © Apple Inc.

This app is built with Apple system frameworks (Swift, SwiftUI, PhotosKit, SwiftData,
Core ML, Foundation Models, AuthenticationServices, Security/Keychain, MapKit,
CoreLocation, Network, and others) and uses SF Symbols. These are provided by Apple
under the Apple SDK and SF Symbols license terms and are not open-source dependencies.
SF Symbols is a trademark of Apple Inc.
"""
