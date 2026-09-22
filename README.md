# ART-ctl-script
 
A CTL port of the darktable "3D Colorimetric Film" (3DCF) tone/color module
(src/iop/3dcf.c + data/kernels/3dcf.cl) for use with ART
(https://rawtherapee.com / ART-ctlscripts).

Copyright (C) 2026, ported by Christian Bouhon from the Libre DT-lab fork.
Original module: Copyright (C) 2026 Libre DT-lab developers.
https://github.com/Christian-Bouhon/libre-dt-lab/blob/main/src/iop/3dcf.c

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

---------------------------------------------------------------------------
Acknowledgments and Technical References (Libre DT-lab):

- ACES 2.0 Single-Stage Tone Scale (SSTS) : Academy Color Encoding System,
    Michaelis-Menten parametric curve with flare compensation. The SSTS defines
    the "texture of light" — the character of tone reproduction from scene-linear
    to display luminance.
    Reference: aces-core / lib / Lib.Academy.Tonescale.ctl

- Spektrafilm spectral film simulation : Andrea Volpato (2024). Inspiration
    for the spectral gamut management approach — film dye absorption naturally
    limits chroma via smooth asymptotic roll-off in CIE xy chromaticity space,
    preserving perceived hue while compressing out-of-gamut colors.
    https://github.com/andreavolpato/spektrafilm

- ACES 1.0 Filmic Tone Mapping Curve : Krzysztof Narkowicz (2016). Reference
    for early tone scale work, prior to adopting ACES 2.0 SSTS.
    https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/

- Bradford chromatic adaptation transform (D50 ↔ D65) : standard CAT used
    for white point adaptation between Rec.2020 D65 and the D50 working space.

- BT.1886 electro-optical transfer function : ITU-R BT.1886 reference EOTF
    for gamma correction in the display pipeline.

- CIE 1931 standard observer (XYZ colour matching functions) : foundation
    for all spectral and colorimetric computations.

- Rec.2020 colour space : ITU-R BT.2020 ultra-high definition television
    standard, used as the working space for wide-gamut spectral processing.

- XYZ sigmoid curve (GIMP 3 Python plug-in) : discuss.pixls.us (2025).
    Inspiration for the X/Z chroma contrast feature — applying independent
    sigmoid contrast curves on the CIE X and Z chromaticity axes to steer
    the asymmetry of the chromatic response.
    https://discuss.pixls.us/t/python-plug-in-for-gimp3-xyz-sigmoid-curve/60096
