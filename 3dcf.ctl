/* 3dcf.ctl
 
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

---------------------------------------------------------------------------
 
Pipeline (mirrors dt_st_pipeline_eval() 1:1):
1. D50-adapted Rec.2020 RGB -> D50 XYZ
2. ACES 2.0 SSTS tone map on luminance Y only
3. BT.1886 OETF + contrast S-curve (toe/shoulder powers)
4. Mid-tone gamma adjustment
5. Chromaticity ratio scaling: x = ratio * Y
5b. Chroma contrast: independent sigmoid on the CIE-xz offset from white
    (X/Z axes only, Y untouched), applied before the spectral gamut roll-off
6. Spectral gamut: film-like chromaticity roll-off in CIE xy
7. XYZ -> output RGB via output matrix
8. Abney hue rotation + highlight desaturation
9. Vibrance (saturation with high-sat protection)
10. Chromatic contrast (luminance-adaptive mid-tone saturation boost)
11. Gamut compression safety net + optional output gamut protection
12. Color-look matrix blend

---------------------------------------------------------------------------

Notes:
- The script receives and returns LINEAR values in the declared color
  space ("rec2020"); 1.0 corresponds to 100 nits.  This matches the ART
  CTL contract (see OpenDRT for ART).  No CAT is needed: ART's rec2020
  working space is D50-adapted, same as the module's.
- With @ART-lut the transform is evaluated as a 64^3 LUT sampled in
  PQ-shaper space; input values above 100 nits clamp to the LUT edge,
  as for all ART CTL scripts.  Remove the @ART-lut line to evaluate
  per-pixel (slower, full HDR range).
- The module's "HL detail recovery" (guided filter) is not portable to
  CTL and is omitted here.
*/

// @ART-label: "3D Colorimetric Film (3DCF)"
// @ART-colorspace: "rec2020"
// @ART-lut: 64

// @ART-param: ["input_exposure", "Input exposure (EV)", -2.0, 2.0, 0.0, 0.05, "Tone"]
// @ART-param: ["peak_luminance", "Peak luminance (%)", -100.0, 100.0, 0.0, 1.0, "Tone"]
// @ART-param: ["contrast", "Contrast", -2.0, 2.0, 0.0, 0.01, "Tone"]
// @ART-param: ["contrast_pivot", "Contrast pivot", -0.49, 0.49, 0.0, 0.01, "Tone"]
// @ART-param: ["shoulder_power", "Shoulder power", -0.75, 2.0, 0.0, 0.01, "Tone"]
// @ART-param: ["toe_power", "Toe power", -0.75, 2.0, 0.0, 0.01, "Tone"]
// @ART-param: ["gamma", "Gamma", -1.0, 1.0, 0.0, 0.01, "Tone"]
// @ART-param: ["color_look", "Color look", ["neutral", "natural look", "portrait", "vibrant", "nature", "blue sky", "soft warm", "soft", "deep cool", "authentic cinema", "bright atmosphere"], 0, "Color"]
// @ART-param: ["look_opacity", "Look opacity", 0.0, 1.0, 1.0, 0.01, "Color"]
// @ART-param: ["vibrance", "Vibrance", -1.0, 1.0, 0.0, 0.01, "Color"]
// @ART-param: ["chromatic_boost", "Chromatic boost", 0.0, 1.0, 0.0, 0.01, "Color"]
// @ART-param: ["chroma_contrast", "Chroma contrast", 0.0, 10.0, 0.0, 0.01, "Color"]
// @ART-param: ["chroma_balance", "X/Z balance", -1.0, 1.0, 0.0, 0.01, "Color"]
// @ART-param: ["output_cs", "Target display", ["sRGB", "Rec. 2020", "Display P3", "ProPhoto RGB", "Adobe RGB"], 1, "Color"]
// @ART-param: ["hl_hue_shift", "Abney rotation", -1.0, 1.0, 0.0, 0.01, "Highlights"]
// @ART-param: ["hl_desaturation", "Highlight roll-off", 0.0, 1.0, 0.25, 0.01, "Highlights"]
// @ART-param: ["hl_desat_threshold", "Desaturation threshold", 0.0, 1.0, 0.5, 0.01, "Highlights"]
// @ART-param: ["gamut_knee", "Gamut knee", 0.0, 1.0, 0.2, 0.01, "Gamut"]
// @ART-param: ["gamut_steepness", "Gamut steepness", 0.0, 1.0, 0.5, 0.01, "Gamut"]

/* ------------------------- constants and tables ------------------------- */

const float INPUT_MATRIX[9] = {
     0.694583654,    0.1426889,  0.126939461,
     0.286466688,  0.668959141, 0.0445741601,
               0,  0.027698433,  0.797489822
};

const float OUTPUT_MATRIX[9] = {
      1.57423051, -0.326162823,  -0.23234596,
    -0.675692502,   1.63832301, 0.0159816076,
     0.023468166, -0.0569022688,   1.25337943
};

const float WHITE_X_RATIO = 0.96421200037;
const float WHITE_Z_RATIO = 0.825188279152;

const float LUMA_REC709[3]  = { 0.2126, 0.7152, 0.0722 };
const float LUMA_REC2020[3] = { 0.2627, 0.6780, 0.0593 };
const float LUMA_P3[3]      = { 0.2289, 0.6918, 0.0793 };
const float LUMA_PROPHOTO[3]= { 0.2880, 0.7119, 0.0001 };
const float LUMA_ADOBE[3]   = { 0.2973, 0.6274, 0.0753 };

const float SPECTRAL_BOUNDARY[360] = {
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,    0.2210142,
       0.2210142,     0.343572,     0.343572,     0.343572,     0.343572,    0.4043592,
       0.4043592,    0.4396615,    0.4626427,    0.4907236,    0.5180794,    0.5492317,
       0.5590972,    0.5625348,    0.5675602,    0.5690228,       0.5673,       0.5673,
       0.5599328,    0.5599328,    0.5599328,    0.5433914,    0.5433914,    0.5433914,
       0.5433914,    0.5433914,    0.5154695,    0.5154695,    0.5154695,    0.5154695,
       0.5154695,    0.5154695,    0.5154695,    0.4717204,    0.4717204,    0.4717204,
       0.4717204,    0.4717204,    0.4717204,    0.4717204,    0.4717204,    0.4717204,
       0.4717204,    0.4717204,    0.4191027,    0.4191027,    0.4191027,    0.4191027,
       0.4191027,    0.4191027,    0.4191027,    0.4191027,    0.4191027,    0.4191027,
       0.4191027,    0.4191027,    0.4191027,    0.4191027,    0.3724765,    0.3724765,
       0.3724765,    0.3724765,    0.3724765,    0.3724765,    0.3724765,    0.3724765,
       0.3724765,    0.3724765,    0.3724765,    0.3724765,    0.3724765,    0.3724765,
       0.3724765,    0.3724765,    0.3724765,    0.3724765,    0.3448245,    0.3448245,
       0.3448245,    0.3448245,    0.3448245,    0.3448245,    0.3448245,    0.3448245,
       0.3448245,    0.3448245,    0.3448245,    0.3448245,    0.3448245,    0.3448245,
       0.3448245,    0.3448245,    0.3448245,    0.3448245,    0.3371611,    0.3371611,
       0.3371611,    0.3371611,    0.3371611,    0.3371611,    0.3371611,    0.3371611,
       0.3371611,    0.3371611,    0.3371611,    0.3371611,    0.3371611,    0.3371611,
       0.3371611,    0.3400847,    0.3400847,    0.3400847,    0.3400847,    0.3400847,
       0.3400847,    0.3400847,    0.3400847,    0.3400847,    0.3400847,    0.3400847,
       0.3394556,    0.3394556,    0.3394556,    0.3394556,    0.3394556,    0.3394556,
       0.3394556,    0.3394556,    0.3394556,    0.3307354,    0.3307354,    0.3307354,
       0.3307354,    0.3307354,    0.3307354,    0.3307354,    0.3307354,    0.3197035,
       0.3197035,    0.3197035,    0.3197035,    0.3197035,    0.3197035,    0.3197035,
        0.310527,     0.310527,     0.310527,     0.310527,     0.310527,     0.310527,
        0.310527,    0.3028925,    0.3028925,    0.3028925,    0.3028925,    0.3028925,
       0.3028925,    0.3028925,    0.2968815,    0.2968815,    0.2968815,    0.2968815,
       0.2968815,    0.2968815,    0.2968815,    0.2930738,    0.2930738,    0.2930738,
       0.2930738,    0.2930738,    0.2930738,    0.2930738,    0.2921591,    0.2921591,
       0.2921591,    0.2921591,    0.2921591,    0.2921591,    0.2921591,    0.2946627,
       0.2946627,    0.2946627,    0.2946627,    0.2946627,    0.2946627,    0.2946627,
       0.3008572,    0.3008572,    0.3008572,    0.3008572,    0.3008572,    0.3008572,
       0.3106021,    0.3106021,    0.3106021,    0.3106021,    0.3106021,    0.3106021,
       0.3234627,    0.3234627,    0.3234627,    0.3234627,    0.3234627,    0.3388181,
       0.3388181,    0.3388181,    0.3388181,    0.3388181,    0.3559532,    0.3559532,
       0.3559532,    0.3739147,    0.3739147,    0.3739147,    0.3739147,    0.3916155,
       0.3916155,    0.4079261,    0.4079261,    0.4228945,    0.4228945,    0.4357092,
       0.4463651,    0.4550005,    0.4676606,    0.4794847,    0.4887248,    0.4887248,
       0.4887248,    0.4887248,    0.4887248,    0.4887248,    0.4887248,    0.4887248,
       0.4887248,    0.4887248,    0.4887248,    0.4887248,    0.4887248,    0.4887248,
       0.4887248,    0.4887248,    0.4887248,    0.4887248,    0.4887248,    0.4887248,
       0.4887248,    0.4887248,    0.4887248,    0.4887248,    0.4887248,    0.4887248,
       0.4887248,    0.4887248,    0.4887248,    0.4887248,    0.4887248,    0.4887248,
       0.4887248,    0.4887248,    0.4887248,    0.4887248,    0.4887248,    0.4887248
};

const float GAMUT_REACH[360] = {
        215.3347,      216.654,     217.8843,     219.0515,     220.1436,     221.1659,
        222.1217,     223.0116,     223.8366,     224.5983,     225.2992,     225.9317,
        226.5103,       227.04,      227.525,       227.97,     228.3796,     228.7584,
        229.1089,     229.4423,     223.6872,      214.168,     205.4743,     197.5074,
        190.1822,     183.4275,     177.4093,     171.7142,     166.0192,     161.2611,
         156.512,     152.0999,     148.0912,     144.0825,     140.6168,     137.1986,
        133.9643,     131.0248,     128.0854,     125.4802,     122.9347,     120.4919,
        118.2746,     116.0574,     114.0555,     112.1152,     110.2321,     108.5279,
        106.8237,     105.2633,     103.7625,     102.2921,     100.9683,     99.64443,
        98.41933,     97.25076,       96.096,     95.06489,     94.03378,     93.07201,
        92.16363,     91.25852,     90.46065,     89.66278,      88.9145,     88.21698,
        87.51945,        86.91,     86.30434,     85.73459,     85.21377,     84.69295,
        84.24227,     83.80045,      83.3848,     83.01721,     82.64962,     82.33952,
        82.04231,     81.76405,     81.53416,     81.30428,     81.12289,     80.95801,
        80.83521,     80.72168,     80.65045,     80.59034,     80.57131,      80.5671,
        80.60517,     80.65601,     80.75144,     80.85907,     81.01254,     81.17904,
        81.39567,     81.62642,     81.90923,     82.20887,      82.5598,     82.93072,
        83.35113,      83.7947,     84.29233,     84.81635,     85.39422,     86.00119,
        86.66454,     87.35604,     88.10696,     88.88807,     89.72918,     90.60318,
         91.5398,     92.51119,     93.54398,     94.61283,     95.74192,     96.90921,
        98.13804,     99.40525,     100.7364,     102.1058,     103.5402,     105.0123,
        106.5526,     108.1323,     109.7819,     111.4714,     113.2362,     115.0423,
         116.926,     118.8525,     120.8616,     122.9127,     125.0489,     127.2277,
        129.4942,     131.8025,     134.2044,     136.6454,     139.1848,     141.7574,
        144.4284,      147.119,     149.9109,      152.713,     155.6224,     158.5384,
        161.5685,      164.597,     167.7418,     170.8784,     174.1376,     177.3822,
        180.7529,     184.0999,     187.5802,     191.0242,     194.6132,     198.1496,
        201.8634,     205.4993,     209.3508,     213.1094,     217.1087,     220.9885,
        225.1512,     229.1491,     233.5194,     237.7211,     242.3097,     246.7144,
         251.554,     256.1942,     261.3218,      266.209,     271.6587,     276.8345,
        282.6281,     288.1141,     294.3002,     300.1502,     306.7552,     313.0006,
        320.0341,     326.6594,     334.1481,     341.2055,     349.1582,      356.623,
        365.0592,      373.005,     381.9876,     390.4526,     400.0301,     409.0992,
        419.3687,     429.0977,     440.1098,     450.6002,     462.4489,     473.7538,
        486.5134,     498.7229,     512.5187,     525.7194,     540.6399,     554.9099,
             571,     586.3564,       603.69,      620.207,     638.9976,     656.9055,
        677.1592,     696.3456,     718.0686,     738.6092,     761.8796,     783.8557,
         808.716,     832.0389,     858.6324,     883.5505,     911.9438,     938.5311,
        969.0005,      997.369,     1029.949,     1060.286,     1094.999,     1127.444,
        1164.363,     1198.989,     1237.193,     1273.051,     1313.631,     1351.658,
        1394.652,     1434.909,     1479.369,     1521.299,     1568.311,     1611.984,
        1660.623,     1705.853,     1756.344,     1803.038,      1855.55,     1903.872,
        1958.616,     2008.997,     2065.341,     2116.532,     2174.751,      2227.24,
        2286.711,     2334.725,     2382.301,     2412.861,     2440.195,     2454.065,
          2459.1,     2451.716,     2434.684,     2404.689,     2367.156,      2312.63,
        2255.384,     2181.093,     2107.342,     2016.329,     1927.029,     1817.553,
         1712.68,     1587.076,     1470.869,     1330.427,     1206.145,     1053.684,
        932.3432,     788.2919,     696.2423,     611.5339,     544.9968,       492.61,
        450.6536,     416.3276,      387.834,     363.8766,     343.4601,       325.87,
        310.5931,     297.2294,     285.4605,     275.0344,     265.7511,     257.4504,
        250.0003,     243.2918,     237.2343,     231.7517,     226.7796,     222.2626,
        218.1537,     214.4123,     210.9936,     207.8674,     204.9897,     202.3291,
        199.8576,     197.5516,     195.3906,      193.357,     191.4359,     189.6146,
        187.8825,     186.2307,     184.6517,     183.1391,     181.6877,     180.2931,
        178.9515,     177.6598,     176.4154,     175.2159,     174.0593,     172.9439,
        171.8682,     170.8309,     169.8309,      168.867,     167.9384,     167.0444,
        166.1842,     165.3573,      164.563,     163.8009,     163.0706,     162.3717,
               0,            0,            0,            0,            0,            0,
               0,            0,            0,            0,            0,            0,
               0,            0,            0,            0,            0,            0
};

const float COLOR_LOOKS[11][9] = {
    {             1,             0,             0,             0,             1,             0,             0,             0,             1 },
    {         1.076,        -0.047,        -0.058,        -0.014,         1.044,        -0.052,        -0.105,         0.049,         1.076 },
    {         1.029,        -0.023,        -0.002,        -0.008,         1.008,         0.007,        -0.074,         0.046,          1.01 },
    {         1.074,        -0.054,        -0.071,         0.006,         1.009,        -0.059,        -0.103,          0.06,         1.086 },
    {         1.084,        -0.006,        -0.093,        -0.074,         1.008,          0.06,        -0.011,         0.005,         1.024 },
    {         1.218,        -0.119,        -0.099,         0.007,         1.076,        -0.069,        -0.192,         0.048,         1.154 },
    {          1.05,          0.02,         -0.01,         -0.02,          1.02,             0,         -0.01,         -0.02,          1.03 },
    {         1.082,        -0.051,        -0.047,         -0.02,         1.052,        -0.045,         0.103,         0.042,         1.073 },
    {          0.98,         -0.01,         -0.01,             0,          1.05,         -0.02,          0.02,          0.01,           1.1 },
    {          1.02,         -0.01,         -0.01,         -0.03,          1.04,         -0.01,             0,         -0.03,          1.03 },
    {         1.067,        -0.049,        -0.031,        -0.017,         1.033,        -0.026,        -0.088,         0.042,         1.055 }
};

const float GAMUT_FWD[5][9] = {
    {      1.660491,   -0.58764114,   -0.07284986,   -0.12455047,     1.1328999,   -0.00834942,   -0.01815076,    -0.1005789,    1.11872966 },
    {             1,             0,             0,             0,             1,             0,             0,             0,             1 },
    {    1.34357825,   -0.28217967,   -0.06139858,   -0.06529745,    1.07578792,   -0.01049046,    0.00282179,   -0.01959849,    1.01677671 },
    {    0.83510709,    0.04879602,     0.1159357,    0.05402452,    0.92897841,    0.01705626,   -0.00234169,    0.03633707,    0.96596433 },
    {    1.15197839,   -0.09750306,   -0.05447534,   -0.12455047,     1.1328999,   -0.00834942,   -0.02253038,   -0.04980651,    1.07233689 }
};

const float GAMUT_INV[5][9] = {
    {     0.6274039,    0.32928304,    0.04331307,    0.06909729,     0.9195404,    0.01136232,    0.01639144,    0.08801331,    0.89559525 },
    {             1,             0,             0,             0,             1,             0,             0,             0,             1 },
    {    0.75383303,    0.19859737,     0.0475696,    0.04574385,    0.94177722,    0.01247893,   -0.00121034,    0.01760172,    0.98360862 },
    {    1.20076809,   -0.05747473,   -0.14310217,   -0.06993213,    1.08054256,   -0.01068609,    0.00554157,   -0.04078654,    1.03528999 },
    {    0.87733384,    0.07749371,    0.04517245,    0.09662259,    0.89152732,    0.01185009,    0.02292106,    0.04303669,    0.93404225 }
};

const float ST_GAMUT_SHAPE_REF = 2.090563;

/* ------------------------------ math helpers ----------------------------- */

float st_fmin(float a, float b)
{
    if (a < b) {
        return a;
    } else {
        return b;
    }
}

float st_fmax(float a, float b)
{
    if (a > b) {
        return a;
    } else {
        return b;
    }
}

float st_fabs(float x)
{
    return fabs(x);
}

float st_clamp(float x, float lo, float hi)
{
    return st_fmax(st_fmin(x, hi), lo);
}

float st_exp2(float x)
{
    return pow(2.0, x);
}

float st_log2(float x)
{
    return log(x) / 0.6931471805599453;
}

float st_sanitize(float x)
{
    if (isfinite_f(x)) {
        return st_fmax(x, 0.0);
    } else {
        return 0.0;
    }
}

float st_spow(float a, float b)
{
    if (a <= 0.0) {
        return a;
    } else {
        return pow(a, b);
    }
}

/* Luma coefficients for the selected output color space */
float st_luma(int cs, int i)
{
    if (cs == 0) {
        return LUMA_REC709[i];
    } else if (cs == 2) {
        return LUMA_P3[i];
    } else if (cs == 3) {
        return LUMA_PROPHOTO[i];
    } else if (cs == 4) {
        return LUMA_ADOBE[i];
    } else {
        return LUMA_REC2020[i];
    }
}

/* --------------------------- ACES 2.0 SSTS ------------------------------- */

float[6] st_ssts_init(float peak)
{
    float n_r = 100.0;
    float g = 1.15;
    float c = 0.18;
    float c_d = 10.013;
    float w_g = 0.14;
    float t_1 = 0.04;
    float r_hit_min = 128.0;
    float r_hit_max = 896.0;

    float n = st_fmax(peak, 1.0);

    float r_hit = r_hit_min + (r_hit_max - r_hit_min)
                * (log(n / n_r) / log(10000.0 / 100.0));

    float m_0 = n / n_r;
    float m_1 = 0.5 * (m_0 + sqrt(m_0 * (m_0 + 4.0 * t_1)));

    float u = pow((r_hit / m_1) / ((r_hit / m_1) + 1.0), g);
    float m = m_1 / u;

    float w_i = log(n / 100.0) / log(2.0);
    float c_t = (c_d / n_r) * (1.0 + w_i * w_g);

    float g_ip = 0.5 * (c_t + sqrt(c_t * (c_t + 4.0 * t_1)));
    float g_ipp2 = -(m_1 * pow(g_ip / m, 1.0 / g))
                  / (pow(g_ip / m, 1.0 / g) - 1.0);
    float w_2 = c / g_ipp2;
    float s_2 = w_2 * m_1;

    float u_2 = pow((r_hit / m_1) / ((r_hit / m_1) + w_2), g);
    float m_2 = m_1 / u_2;

    float res[6] = { s_2, m_2, g, t_1, n_r, n };
    return res;
}

float st_ssts_fwd(float s_2, float m_2, float g, float t_1, float n_r, float x)
{
    if (x <= 0.0) {
        return 0.0;
    }
    float f = m_2 * pow(x / (x + s_2), g);
    float h = (f * f) / (f + t_1);
    return h * n_r;
}

/* ---------------------- tone mapped luminance ---------------------------- */

float st_compute_y_tm(float y_scene, float exposure_factor, float ssts[6],
                      float contrast, float contrast_pivot, float toe_power,
                      float shoulder_power)
{
    float s_2 = ssts[0];
    float m_2 = ssts[1];
    float g = ssts[2];
    float t_1 = ssts[3];
    float n_r = ssts[4];
    float n = ssts[5];

    if (n <= 0.0) {
        return 0.0;
    }

    float y_tm = st_ssts_fwd(s_2, m_2, g, t_1, n_r, y_scene * exposure_factor)
               / n_r;

    y_tm = pow(st_fmax(y_tm, 0.0), 1.0 / 2.4);

    y_tm = st_fmin(y_tm, 1.0);

    if (contrast != 1.0 || toe_power != 1.0 || shoulder_power != 1.0) {
        float c = contrast;
        float p = contrast_pivot;
        float ct = toe_power;
        float cs = shoulder_power;
        if (y_tm <= p) {
            float t = 0.0;
            if (p > 0.0) {
                t = y_tm / p;
            }
            float exp_eff = c * (ct + (1.0 - ct) * t);
            y_tm = p * pow(st_fmax(y_tm / p, 0.0), exp_eff);
        } else {
            float rp = 1.0 - p;
            float t = 0.0;
            if (rp > 0.0) {
                t = (1.0 - y_tm) / rp;
            }
            float exp_eff = c * (cs + (1.0 - cs) * t);
            y_tm = 1.0 - rp * pow(st_fmax((1.0 - y_tm) / rp, 0.0), exp_eff);
        }
    }

    return y_tm;
}

/* ------------------ highlight desaturation weight ------------------------ */

float st_desat_weight(float y_norm, float hl_desat, float threshold)
{
    if (hl_desat <= 0.0 || y_norm <= threshold) {
        return 0.0;
    }
    if (!isfinite_f(y_norm)) {
        return 0.0;
    }
    float t = st_fmax(y_norm - threshold, 0.0) / y_norm;
    float x = st_fmin(t * hl_desat, 1.0);
    return x * x;
}

/* ----------------------- spectral gamut helpers -------------------------- */

float st_reach_from_table(float h)
{
    if (!isfinite_f(h)) {
        return 0.0;
    }
    float hw = fmod(h, 360.0);
    if (hw < 0.0) {
        hw = hw + 360.0;
    }
    int i0 = hw;
    int i1 = (i0 + 1) % 360;
    float t = hw - i0;
    return GAMUT_REACH[i0] + t * (GAMUT_REACH[i1] - GAMUT_REACH[i0]);
}

float st_chroma_norm(float h)
{
    float hr = h * 0.017453292519943295;
    float a = cos(hr);
    float b = sin(hr);
    float a2 = a * a - b * b;
    float b2 = 2.0 * a * b;
    float a3 = 4.0 * a * a * a - 3.0 * a;
    float b3 = 3.0 * b - 4.0 * b * b * b;
    return 11.34072 * a + 16.46899 * a2 + 7.88380 * a3
         + 14.66441 * b - 6.37224 * b2 + 9.19364 * b3 + 77.12896;
}

float[2] st_spectral_gamut(float x_tm, float z_tm, float y_tm,
                           float white_x_ratio, float white_z_ratio,
                           float knee, float steepness)
{
    float xr = x_tm;
    float zr = z_tm;
    float res[2] = { xr, zr };
    if (y_tm <= 0.0) {
        return res;
    }
    if (!isfinite_f(xr) || !isfinite_f(zr)) {
        return res;
    }

    float sum = xr + y_tm + zr;
    if (sum <= 0.0) {
        return res;
    }
    float cie_x = x_tm / sum;
    float cie_z = z_tm / sum;

    float wy = 1.0;
    float wx = white_x_ratio;
    float wz = white_z_ratio;
    float wsum = wx + wy + wz;
    float white_cie_x = wx / wsum;
    float white_cie_z = wz / wsum;

    float dx = cie_x - white_cie_x;
    float dz = cie_z - white_cie_z;
    float chroma_sq = dx * dx + dz * dz;

    float angle_deg = atan2(dz, dx) * 57.29577951308232;
    if (angle_deg < 0.0) {
        angle_deg = angle_deg + 360.0;
    }
    if (angle_deg >= 360.0) {
        angle_deg = angle_deg - 360.0;
    }
    int bin = angle_deg;
    int next = (bin + 1) % 360;
    float frac = angle_deg - bin;
    float max_dist = SPECTRAL_BOUNDARY[bin]
                   + frac * (SPECTRAL_BOUNDARY[next] - SPECTRAL_BOUNDARY[bin]);
    float target_dist = max_dist * 0.92;

    if (max_dist > 0.0 && chroma_sq > target_dist * target_dist) {
        float chroma = sqrt(chroma_sq);
        float excess = chroma - target_dist;
        float bsteep = st_fmax(target_dist * 0.05, 0.001);
        float compression = excess / (excess + bsteep);
        float scale = (chroma - compression * excess) / chroma;

        cie_x = white_cie_x + scale * dx;
        cie_z = white_cie_z + scale * dz;
        float y_new = 1.0 - cie_x - cie_z;
        if (y_new > 0.0) {
            float S_new = y_tm / y_new;
            xr = cie_x * S_new;
            zr = cie_z * S_new;
            dx = cie_x - white_cie_x;
            dz = cie_z - white_cie_z;
            chroma_sq = dx * dx + dz * dz;
        }
    }

    angle_deg = atan2(dz, dx) * 57.29577951308232;
    if (angle_deg < 0.0) {
        angle_deg = angle_deg + 360.0;
    }
    if (angle_deg >= 360.0) {
        angle_deg = angle_deg - 360.0;
    }
    float shape = st_reach_from_table(angle_deg)
                / st_fmax(st_chroma_norm(angle_deg), 1e-6);
    float shape_norm = st_fmax(shape / ST_GAMUT_SHAPE_REF, 0.0);
    float knee_mod = knee * sqrt(shape_norm);

    if (chroma_sq > knee_mod * knee_mod) {
        float chroma = sqrt(chroma_sq);
        float excess = chroma - knee_mod;
        float compression = excess / (excess + steepness);
        float scale = (chroma - compression * excess) / chroma;

        float x_new = white_cie_x + scale * dx;
        float z_new = white_cie_z + scale * dz;
        float y_new = 1.0 - x_new - z_new;

        if (y_new > 0.0) {
            float S_new = y_tm / y_new;
            xr = x_new * S_new;
            zr = z_new * S_new;
        }
    }

    res[0] = xr;
    res[1] = zr;
    return res;
}

/* Independent sigmoid contrast on the CIE-xz offset from white, applied
   BEFORE st_spectral_gamut() so its knee compression absorbs any excursion
   this creates. Operates on chroma normalized by the spectral locus radius
   for the pixel's hue angle -- NOT on raw x_tm/z_tm, whose absolute scale
   depends on y_tm and would make the contrast luminance-dependent instead
   of saturation-dependent. Y is intentionally left untouched.

   Normalization mirrors sigmoidAdj() from Ohnishi Yasuo's XYZ sigmoid curve
   GIMP plug-in (GPLv3): the sigmoid is rescaled so f(0)=0, f(1)=1 exactly,
   here applied per-axis to the [-1,1]-normalized chroma offset instead of
   to a raw channel value. gain_x/z, shift_x/z, sig0_x/z and inv_range_x/z
   are precomputed once per image in ART_main (mirrors dt_st_compute_context). */
float[2] st_chroma_contrast_sigmoid(float x_tm, float z_tm, float y_tm,
                                    float white_x_ratio, float white_z_ratio,
                                    float gain_x, float shift_x, float sig0_x, float inv_range_x,
                                    float gain_z, float shift_z, float sig0_z, float inv_range_z)
{
    float xr = x_tm;
    float zr = z_tm;
    float res[2] = { xr, zr };

    if (y_tm <= 0.0) {
        return res;
    }
    if (!isfinite_f(xr) || !isfinite_f(zr)) {
        return res;
    }

    float sum = xr + y_tm + zr;
    if (sum <= 0.0) {
        return res;
    }
    float cie_x = xr / sum;
    float cie_z = zr / sum;

    float wy = 1.0;
    float wx = white_x_ratio;
    float wz = white_z_ratio;
    float wsum = wx + wy + wz;
    float white_cie_x = wx / wsum;
    float white_cie_z = wz / wsum;

    float dx = cie_x - white_cie_x;
    float dz = cie_z - white_cie_z;

    float angle_deg = atan2(dz, dx) * 57.29577951308232;
    if (angle_deg < 0.0) {
        angle_deg = angle_deg + 360.0;
    }
    if (angle_deg >= 360.0) {
        angle_deg = angle_deg - 360.0;
    }
    int bin = angle_deg;
    int next = (bin + 1) % 360;
    float frac = angle_deg - bin;
    float max_dist = SPECTRAL_BOUNDARY[bin]
                   + frac * (SPECTRAL_BOUNDARY[next] - SPECTRAL_BOUNDARY[bin]);
    if (max_dist <= 0.0) {
        return res;
    }

    /* Normalize each axis independently to [-1, 1] by the spectral radius,
       remap to [0, 1] for the sigmoid, then back. */
    float u = st_clamp(dx / max_dist, -1.0, 1.0);
    float wv = st_clamp(dz / max_dist, -1.0, 1.0);

    float u01 = 0.5 * (u + 1.0);
    float w01 = 0.5 * (wv + 1.0);

    float sig_u = 1.0 / (1.0 + exp(-gain_x * (u01 - shift_x)));
    float sig_w = 1.0 / (1.0 + exp(-gain_z * (w01 - shift_z)));

    float u01_new = (sig_u - sig0_x) * inv_range_x;
    float w01_new = (sig_w - sig0_z) * inv_range_z;

    float u_new = 2.0 * u01_new - 1.0;
    float w_new = 2.0 * w01_new - 1.0;

    float cie_x_new = white_cie_x + u_new * max_dist;
    float cie_z_new = white_cie_z + w_new * max_dist;
    float y_new = 1.0 - cie_x_new - cie_z_new;

    if (y_new > 0.0) {
        float S_new = y_tm / y_new;
        xr = cie_x_new * S_new;
        zr = cie_z_new * S_new;
    }

    res[0] = xr;
    res[1] = zr;
    return res;
}

/* ------------------- gamut compression / protection ---------------------- */

float[3] st_gamut_compress(float rgb[3], float lc[3])
{
    float luma = lc[0] * rgb[0] + lc[1] * rgb[1] + lc[2] * rgb[2];
    float anchor = 1.0;
    if (luma > 1e-4) {
        anchor = luma;
    }

    float t = 0.0;
    if (rgb[0] < 0.0) {
        float d = anchor - rgb[0];
        float ti = 1.0;
        if (d > 1e-6) {
            ti = (-rgb[0]) / d;
        }
        if (ti > t) t = ti;
    } else if (rgb[0] > 1.0) {
        float d = rgb[0] - anchor;
        float ti = 1.0;
        if (d > 1e-6) {
            ti = (rgb[0] - 1.0) / d;
        }
        if (ti > t) t = ti;
    }
    if (rgb[1] < 0.0) {
        float d = anchor - rgb[1];
        float ti = 1.0;
        if (d > 1e-6) {
            ti = (-rgb[1]) / d;
        }
        if (ti > t) t = ti;
    } else if (rgb[1] > 1.0) {
        float d = rgb[1] - anchor;
        float ti = 1.0;
        if (d > 1e-6) {
            ti = (rgb[1] - 1.0) / d;
        }
        if (ti > t) t = ti;
    }
    if (rgb[2] < 0.0) {
        float d = anchor - rgb[2];
        float ti = 1.0;
        if (d > 1e-6) {
            ti = (-rgb[2]) / d;
        }
        if (ti > t) t = ti;
    } else if (rgb[2] > 1.0) {
        float d = rgb[2] - anchor;
        float ti = 1.0;
        if (d > 1e-6) {
            ti = (rgb[2] - 1.0) / d;
        }
        if (ti > t) t = ti;
    }

    float res[3] = { rgb[0], rgb[1], rgb[2] };
    if (t <= 0.0) {
        return res;
    }
    float blend = st_fmin(t, 1.0);
    res[0] = (1.0 - blend) * rgb[0] + blend * anchor;
    res[1] = (1.0 - blend) * rgb[1] + blend * anchor;
    res[2] = (1.0 - blend) * rgb[2] + blend * anchor;
    return res;
}

float[3] st_output_gamut_protect(float rgb[3], int cs)
{
    float t0 = GAMUT_FWD[cs][0] * rgb[0] + GAMUT_FWD[cs][1] * rgb[1] + GAMUT_FWD[cs][2] * rgb[2];
    float t1 = GAMUT_FWD[cs][3] * rgb[0] + GAMUT_FWD[cs][4] * rgb[1] + GAMUT_FWD[cs][5] * rgb[2];
    float t2 = GAMUT_FWD[cs][6] * rgb[0] + GAMUT_FWD[cs][7] * rgb[1] + GAMUT_FWD[cs][8] * rgb[2];

    t0 = st_fmax(t0, 0.0);
    t1 = st_fmax(t1, 0.0);
    t2 = st_fmax(t2, 0.0);

    float res[3];
    res[0] = GAMUT_INV[cs][0] * t0 + GAMUT_INV[cs][1] * t1 + GAMUT_INV[cs][2] * t2;
    res[1] = GAMUT_INV[cs][3] * t0 + GAMUT_INV[cs][4] * t1 + GAMUT_INV[cs][5] * t2;
    res[2] = GAMUT_INV[cs][6] * t0 + GAMUT_INV[cs][7] * t1 + GAMUT_INV[cs][8] * t2;
    return res;
}

/* ----------------------------- ART entry --------------------------------- */

void ART_main(varying float r, varying float g, varying float b,
              output varying float rout, output varying float gout,
              output varying float bout, float contrast, float contrast_pivot,
              float gamma, float toe_power, float shoulder_power,
              float peak_luminance, float input_exposure, float vibrance,
              float chromatic_boost, int output_cs, float hl_hue_shift,
              float hl_desaturation, float hl_desat_threshold, float gamut_knee,
              float gamut_steepness, int color_look, float look_opacity,
              float chroma_contrast, float chroma_balance)
{
    /* ---- context scalars (mirrors st_compute_context) ---- */
    float exposure_factor = st_exp2(input_exposure);
    float c_contrast = st_fmax(contrast + 2.25, 0.001);
    float c_pivot = 1.0 - st_clamp(contrast_pivot + 0.5, 0.01, 0.99);
    float c_hl_desat = st_fmax(hl_desaturation, 0.0);
    float c_hl_thresh = st_fmax(hl_desat_threshold, 0.0);
    float c_hl_rotation = hl_hue_shift;
    float c_knee = st_fmax(gamut_knee, 0.0);
    float c_steep = st_fmax(gamut_steepness, 1e-6);
    float c_toe = st_fmax(toe_power + 1.0, 0.0);
    float c_shoulder = st_fmax(shoulder_power + 1.0, 0.0);
    float c_gamma = -st_clamp(gamma, -1.0, 1.0);
    float c_gamma_power = st_exp2(c_gamma);
    float c_vib = st_fmax(vibrance + 1.0, 0.0);
    float c_cboost = st_fmax(chromatic_boost, 0.0);

    /* Chroma contrast sigmoid -- precompute gain/shift/normalization per
       axis (mirrors dt_st_compute_context()). gain guarded away from 0 to
       avoid division by zero in the endpoint normalization; as gain -> 0
       the normalized curve tends to identity. */
    /* Chroma contrast sigmoid -- precompute gain/shift/normalization per
       axis (mirrors dt_st_compute_context()). gain guarded away from 0 to
       avoid division by zero in the endpoint normalization; as gain -> 0
       the normalized curve tends to identity. Pivot is fixed at the neutral
       50% position for both axes (the per-axis pivot offset of the native
       module is a rarely-used refinement, dropped here for a 2-slider UI). */
    float c_sx = 0.5;
    float c_gx = st_fmax(chroma_contrast, 1e-4);
    float c_sig0x = 1.0 / (1.0 + exp(-c_gx * (0.0 - c_sx)));
    float c_sig1x = 1.0 / (1.0 + exp(-c_gx * (1.0 - c_sx)));
    float c_invx = 1.0 / st_fmax(c_sig1x - c_sig0x, 1e-6);

    /* Z contrast derived from the shared chroma contrast and the X/Z
       balance, mirroring _chroma_z_from_x() of the native module:
       b = (X-Z)/(X+Z) => Z = X*(1-b)/(1+b), clamped away from the +-1
       singularities. balance = 0 keeps X and Z symmetric. */
    float c_sz = 0.5;
    float bf = st_clamp(chroma_balance, -0.999, 0.999);
    float z_eff = st_clamp(chroma_contrast * (1.0 - bf) / (1.0 + bf), 0.0, 10.0);
    float c_gz = st_fmax(z_eff, 1e-4);
    float c_sig0z = 1.0 / (1.0 + exp(-c_gz * (0.0 - c_sz)));
    float c_sig1z = 1.0 / (1.0 + exp(-c_gz * (1.0 - c_sz)));
    float c_invz = 1.0 / st_fmax(c_sig1z - c_sig0z, 1e-6);

    int cs = output_cs;
    if (cs < 0 || cs > 4) {
        cs = 1;
    }

    float peak = 200.0 * (1.0 + peak_luminance / 100.0);
    float ssts[6] = st_ssts_init(peak);

    float lc[3] = { st_luma(cs, 0), st_luma(cs, 1), st_luma(cs, 2) };

    /* ---- sanitize input (mirrors process()) ---- */
    float rgb_in[3];
    rgb_in[0] = st_sanitize(r);
    rgb_in[1] = st_sanitize(g);
    rgb_in[2] = st_sanitize(b);

    /* ---- pre-pipeline safety net (mirrors process()/kernel_3dcf) ---- */
    float lum = st_fmax(st_fmax(rgb_in[0], rgb_in[1]), rgb_in[2]);
    float w = st_desat_weight(lum * exposure_factor, c_hl_desat, c_hl_thresh);
    if (w > 0.0 && isfinite_f(w)) {
        float t = st_fmin(w, 1.0);
        float ts = (t * t) / (t * t + (1.0 - t) * (1.0 - t) + 1e-6);
        if (isfinite_f(ts) && ts > 0.0) {
            rgb_in[0] = rgb_in[0] * (1.0 - ts) + lum * ts;
            rgb_in[1] = rgb_in[1] * (1.0 - ts) + lum * ts;
            rgb_in[2] = rgb_in[2] * (1.0 - ts) + lum * ts;
        }
    }

    /* ---- pipeline eval (mirrors dt_st_pipeline_eval) ---- */
    float rv = rgb_in[0];
    float gv = rgb_in[1];
    float bv = rgb_in[2];
    float x_abs = INPUT_MATRIX[0] * rv + INPUT_MATRIX[1] * gv + INPUT_MATRIX[2] * bv;
    float y_abs = INPUT_MATRIX[3] * rv + INPUT_MATRIX[4] * gv + INPUT_MATRIX[5] * bv;
    float z_abs = INPUT_MATRIX[6] * rv + INPUT_MATRIX[7] * gv + INPUT_MATRIX[8] * bv;

    float rgb_out[3];
    rgb_out[0] = 0.0;
    rgb_out[1] = 0.0;
    rgb_out[2] = 0.0;

    if (!(y_abs > 1e-10) || !isfinite_f(y_abs)) {
        /* black output */
    } else {
        float x_ratio = st_clamp(x_abs / y_abs, -100.0, 100.0);
        float z_ratio = st_clamp(z_abs / y_abs, -100.0, 100.0);

        float y_tm = st_compute_y_tm(y_abs, exposure_factor, ssts, c_contrast,
                                     c_pivot, c_toe, c_shoulder);

        if (c_gamma != 0.0) {
            float y_lvl = st_clamp(y_tm, 0.0, 1.0);
            y_lvl = pow(y_lvl, c_gamma_power);
            y_tm = y_lvl;
        }

        float x_tm = x_ratio * y_tm;
        float z_tm = z_ratio * y_tm;

        /* Chroma contrast: independent sigmoid on CIE-xz offset from
           white (X/Z axes only, Y untouched) */
        float cc[2] = st_chroma_contrast_sigmoid(x_tm, z_tm, y_tm,
                                                  WHITE_X_RATIO, WHITE_Z_RATIO,
                                                  c_gx, c_sx, c_sig0x, c_invx,
                                                  c_gz, c_sz, c_sig0z, c_invz);
        x_tm = cc[0];
        z_tm = cc[1];

        float sg[2] = st_spectral_gamut(x_tm, z_tm, y_tm, WHITE_X_RATIO,
                                        WHITE_Z_RATIO, c_knee, c_steep);
        x_tm = sg[0];
        z_tm = sg[1];

        float rgb[3];
        rgb[0] = OUTPUT_MATRIX[0] * x_tm + OUTPUT_MATRIX[1] * y_tm + OUTPUT_MATRIX[2] * z_tm;
        rgb[1] = OUTPUT_MATRIX[3] * x_tm + OUTPUT_MATRIX[4] * y_tm + OUTPUT_MATRIX[5] * z_tm;
        rgb[2] = OUTPUT_MATRIX[6] * x_tm + OUTPUT_MATRIX[7] * y_tm + OUTPUT_MATRIX[8] * z_tm;

        /* Abney hue rotation tied to SSTS compression ratio */
        if (c_hl_rotation != 0.0 && y_abs > 1e-10) {
            float compression = st_fmin(y_tm / (y_abs * exposure_factor), 1.0);
            float comp_factor = 1.0 - compression;
            float exp_power = st_fmax(1.0 * (1.0 - st_fabs(c_hl_rotation)), 0.1);
            float hl_weight = pow(st_fmax(comp_factor, 1e-10), exp_power);
            float angle = c_hl_rotation * hl_weight;
            float ca = cos(angle);
            float sa = sin(angle);
            if (isfinite_f(ca) && isfinite_f(sa)) {
                float y = lc[0] * rgb[0] + lc[1] * rgb[1] + lc[2] * rgb[2];
                float u = rgb[0] - y;
                float v = rgb[2] - y;
                float ur = u * ca - v * sa;
                float vr = u * sa + v * ca;

                float t = 1.0;
                if (ur > 0.0) t = st_fmin(t, (1.0 - y) / ur);
                if (ur < 0.0) t = st_fmin(t, -y / ur);
                if (vr > 0.0) t = st_fmin(t, (1.0 - y) / vr);
                if (vr < 0.0) t = st_fmin(t, -y / vr);
                if (lc[1] != 0.0) {
                    float g_d = -(lc[0] * ur + lc[2] * vr) / lc[1];
                    if (g_d > 0.0) t = st_fmin(t, (1.0 - y) / g_d);
                    if (g_d < 0.0) t = st_fmin(t, -y / g_d);
                }
                t = st_fmax(t, 0.0);
                rgb[0] = y + t * ur;
                rgb[2] = y + t * vr;
                if (lc[1] != 0.0) {
                    rgb[1] = y - (lc[0] / lc[1]) * t * ur - (lc[2] / lc[1]) * t * vr;
                }
            }
        }

        /* Highlight desaturation */
        float y_exposed = y_abs * exposure_factor;
        float w2 = st_desat_weight(y_exposed, c_hl_desat, c_hl_thresh);
        if (w2 > 0.0 && isfinite_f(w2)) {
            float maxc_pre = st_fmax(st_fmax(rgb[0], rgb[1]), rgb[2]);
            float minc_pre = st_fmin(st_fmin(rgb[0], rgb[1]), rgb[2]);
            float sat_pre = 0.0;
            if (maxc_pre > 0.0) {
                sat_pre = (maxc_pre - minc_pre) / maxc_pre;
            }
            float ss_pre = (sat_pre * sat_pre)
                         / (sat_pre * sat_pre + (1.0 - sat_pre) * (1.0 - sat_pre) + 1e-6);

            float w_final = w2;
            if (c_hl_desat > 0.0) {
                float vib_neg = c_hl_desat * ss_pre * 0.35;
                float w_vib = st_desat_weight(y_exposed, 1.0, c_hl_thresh) * vib_neg;
                w_final = st_fmin(w_final + w_vib, 1.0);
            }

            float ts = st_fmin(w_final, 1.0);
            if (isfinite_f(ts)) {
                rgb[0] = rgb[0] * (1.0 - ts) + ts;
                rgb[1] = rgb[1] * (1.0 - ts) + ts;
                rgb[2] = rgb[2] * (1.0 - ts) + ts;
            }
        }

        /* Vibrance */
        if (c_vib != 1.0) {
            float luma = lc[0] * rgb[0] + lc[1] * rgb[1] + lc[2] * rgb[2];
            float maxc = st_fmax(st_fmax(rgb[0], rgb[1]), rgb[2]);
            float minc = st_fmin(st_fmin(rgb[0], rgb[1]), rgb[2]);
            float sat_m = maxc - minc;
            float level = st_fmax(maxc, st_fmax(st_fabs(minc), st_fabs(luma)));
            float sat_norm = 0.0;
            if (level > 0.0) {
                sat_norm = sat_m / level;
            }

            if (c_vib > 1.0) {
                float p = 1.0 - st_fmin(sat_norm, 1.0);
                float vib_gain = 1.0 + (c_vib - 1.0) * (p * p);
                rgb[0] = luma + vib_gain * (rgb[0] - luma);
                rgb[1] = luma + vib_gain * (rgb[1] - luma);
                rgb[2] = luma + vib_gain * (rgb[2] - luma);
            } else {
                rgb[0] = luma + c_vib * (rgb[0] - luma);
                rgb[1] = luma + c_vib * (rgb[1] - luma);
                rgb[2] = luma + c_vib * (rgb[2] - luma);
            }
        }

        /* Chromatic contrast */
        if (c_cboost > 0.0) {
            float luma = lc[0] * rgb[0] + lc[1] * rgb[1] + lc[2] * rgb[2];
            float maxc = st_fmax(st_fmax(rgb[0], rgb[1]), rgb[2]);
            float minc = st_fmin(st_fmin(rgb[0], rgb[1]), rgb[2]);
            float sat_m = maxc - minc;
            float level = st_fmax(maxc, st_fmax(st_fabs(minc), st_fabs(luma)));
            float sat_norm = 0.0;
            if (level > 0.0) {
                sat_norm = sat_m / level;
            }
            float y_mid = 0.18;
            float sigma = 1.85;
            float log_rel = st_log2(st_fmax(y_abs / y_mid, 1e-10));
            float w_gauss = exp(-(log_rel * log_rel) / (2.0 * sigma * sigma));
            float w_mid;
            if (log_rel <= 0.0) {
                w_mid = 1.0;
            } else {
                w_mid = 1.328 * w_gauss - 0.328;
            }
            float pp = 1.0 - st_fmin(sat_norm, 1.0);

            float hue_deg = 0.0;
            if (sat_m > 0.0) {
                if (maxc == rgb[0]) {
                    hue_deg = 60.0 * fmod((rgb[1] - rgb[2]) / sat_m, 6.0);
                } else if (maxc == rgb[1]) {
                    hue_deg = 60.0 * ((rgb[2] - rgb[0]) / sat_m + 2.0);
                } else {
                    hue_deg = 60.0 * ((rgb[0] - rgb[1]) / sat_m + 4.0);
                }
                if (hue_deg < 0.0) {
                    hue_deg = hue_deg + 360.0;
                }
            }
            float hue_mod = 1.0 + 0.1 * cos((hue_deg - 60.0) * 0.017453292519943295);
            float gain = 1.0 + c_cboost * w_mid * (pp * pp) * hue_mod;
            rgb[0] = luma + gain * (rgb[0] - luma);
            rgb[1] = luma + gain * (rgb[1] - luma);
            rgb[2] = luma + gain * (rgb[2] - luma);
        }

        /* Gamut compression safety net */
        float gc[3] = st_gamut_compress(rgb, lc);
        rgb[0] = gc[0];
        rgb[1] = gc[1];
        rgb[2] = gc[2];

        /* Optional output gamut protection */
        if (cs != 1) {
            float ogp[3] = st_output_gamut_protect(rgb, cs);
            rgb[0] = ogp[0];
            rgb[1] = ogp[1];
            rgb[2] = ogp[2];
        }

        rgb_out[0] = 0.0;
        rgb_out[1] = 0.0;
        rgb_out[2] = 0.0;
        if (isfinite_f(rgb[0])) {
            rgb_out[0] = st_fmax(rgb[0], 0.0);
        }
        if (isfinite_f(rgb[1])) {
            rgb_out[1] = st_fmax(rgb[1], 0.0);
        }
        if (isfinite_f(rgb[2])) {
            rgb_out[2] = st_fmax(rgb[2], 0.0);
        }
    }

    /* Color look blend */
    int look_idx = color_look;
    if (look_idx > 10) {
        look_idx = 0;
    }
    if (look_idx > 0) {
        float tr = rgb_out[0] * COLOR_LOOKS[look_idx][0]
                 + rgb_out[1] * COLOR_LOOKS[look_idx][1]
                 + rgb_out[2] * COLOR_LOOKS[look_idx][2];
        float tg = rgb_out[0] * COLOR_LOOKS[look_idx][3]
                 + rgb_out[1] * COLOR_LOOKS[look_idx][4]
                 + rgb_out[2] * COLOR_LOOKS[look_idx][5];
        float tb = rgb_out[0] * COLOR_LOOKS[look_idx][6]
                 + rgb_out[1] * COLOR_LOOKS[look_idx][7]
                 + rgb_out[2] * COLOR_LOOKS[look_idx][8];

        rgb_out[0] = rgb_out[0] * (1.0 - look_opacity) + tr * look_opacity;
        rgb_out[1] = rgb_out[1] * (1.0 - look_opacity) + tg * look_opacity;
        rgb_out[2] = rgb_out[2] * (1.0 - look_opacity) + tb * look_opacity;
        rgb_out[0] = st_fmax(rgb_out[0], 0.0);
        rgb_out[1] = st_fmax(rgb_out[1], 0.0);
        rgb_out[2] = st_fmax(rgb_out[2], 0.0);
    }

    rout = rgb_out[0];
    gout = rgb_out[1];
    bout = rgb_out[2];
}
