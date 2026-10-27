"""Flickerly's original, photograph-independent color targets (encoded sRGB).

OKLab conversion follows Bjorn Ottosson's published matrices:
https://bottosson.github.io/posts/oklab/
These are authored grades, not mixtures of the three upstream NILUT styles.
No portrait/scene images are used for fitting. Hue protection is color based;
it is not face detection, semantic masking, or an image-adaptive enhancement.
"""
import numpy as np

STYLES = (
    (101, "natural", "Natural"),
    (102, "soft-warm", "Soft Warm"),
    (103, "cool-matte", "Cool Matte"),
)
M1 = np.array([[.4122214708, .5363325363, .0514459929],
               [.2119034982, .6806995451, .1073969566],
               [.0883024619, .2817188376, .6299787005]])
M2 = np.array([[.2104542553, .7936177850, -.0040720468],
               [1.9779984951, -2.4285922050, .4505937099],
               [.0259040371, .7827717662, -.8086757660]])


def linearize(rgb):
    return np.where(rgb <= .04045, rgb / 12.92, ((rgb + .055) / 1.055) ** 2.4)


def encode(rgb):
    return np.where(rgb <= .0031308, rgb * 12.92,
                    1.055 * np.maximum(rgb, 0) ** (1 / 2.4) - .055)


def to_lab(rgb):
    return np.cbrt(linearize(rgb) @ M1.T) @ M2.T


def from_lab(lab):
    return (lab @ np.linalg.inv(M2).T) ** 3 @ np.linalg.inv(M1).T


def curve(x, xs, ys):
    """Monotone cubic Hermite curve; smooth without spline overshoot."""
    xs, ys = np.asarray(xs), np.asarray(ys)
    h, d = np.diff(xs), np.diff(ys) / np.diff(xs)
    slopes = np.r_[d[0], 2 / (1 / d[:-1] + 1 / d[1:]), d[-1]]
    i = np.clip(np.searchsorted(xs, x, side="right") - 1, 0, len(xs) - 2)
    t = (x - xs[i]) / h[i]
    return ((2*t**3-3*t**2+1)*ys[i] + (t**3-2*t**2+t)*h[i]*slopes[i]
            + (-2*t**3+3*t**2)*ys[i+1] + (t**3-t**2)*h[i]*slopes[i+1])


def hue_weight(hue, center, width):
    distance = np.arctan2(np.sin(hue-center), np.cos(hue-center))
    return np.exp(-.5 * (distance/width)**2)


def grade(rgb, index):
    lab = to_lab(np.asarray(rgb, dtype=np.float64))
    light, a, b = np.moveaxis(lab, -1, 0)
    chroma, hue = np.hypot(a, b), np.arctan2(b, a)
    envelope = np.sin(np.pi * np.clip(light, 0, 1)) ** 1.2
    chromatic = 1 - np.exp(-(chroma/.035)**2)
    skin = hue_weight(hue, np.deg2rad(48), np.deg2rad(27)) * chromatic
    green = hue_weight(hue, np.deg2rad(145), np.deg2rad(28)) * chromatic
    blue = hue_weight(hue, np.deg2rad(258), np.deg2rad(26)) * chromatic
    xs = [0, .075, .2, .4, .6, .8, .94, 1]
    if index == 0:
        light_out = curve(light, xs, [0, .020, .090, .310, .635, .880, .975, 1])
        light_out = light_out*(1-.35*skin) + light*.35*skin
        # Clear daylight contrast: dense shadows, luminous upper midtones,
        # emerald greens and cleaner cyan-blues, with a neutral gray axis.
        scale = 1.08 - .16*green + .10*blue - .16*np.clip((chroma-.13)/.16, 0, 1)
        rotation = (np.deg2rad(16)*green - np.deg2rad(9)*blue)*envelope*(1-.85*skin)
        cast_a, cast_b = 0., 0.
    elif index == 1:
        light_out = curve(light, xs, [.075, .12, .25, .465, .665, .835, .948, 1])
        scale = .80 + .15*skin - .03*green
        rotation = (-np.deg2rad(10)*green - np.deg2rad(6)*blue)*envelope*(1-skin)
        # Golden midtones, quieter olive foliage and cooler deep shadows.
        # The warm treatment tapers at white and around skin-like hues.
        shadow = np.exp(-((light-.19)/.19)**2)
        cast_a = (.006*envelope-.002*shadow)*(1-.90*skin)
        cast_b = (.033*envelope-.010*shadow)*(1-.88*skin)
    else:
        light_out = curve(light, xs, [.16, .18, .245, .427, .61, .794, .936, 1])
        scale = .86 + .09*skin - .04*green
        rotation = (np.deg2rad(10)*green - np.deg2rad(5)*blue)*envelope*(1-skin)
        shadow = np.exp(-((light-.25)/.27)**2)*(1-light)**.5
        cast_a = -.0045*shadow*(1-.9*skin)
        cast_b = -.011*shadow*(1-.9*skin)
    a_out = chroma*scale*np.cos(hue+rotation) + cast_a
    b_out = chroma*scale*np.sin(hue+rotation) + cast_b
    # Compress chroma along a constant OKLab hue into the sRGB gamut.
    # Leave a tiny margin so quantization cannot introduce out-of-range values.
    lo, hi = np.zeros_like(light), np.ones_like(light)
    for _ in range(16):
        factor = (lo+hi)/2
        candidate = from_lab(np.stack([light_out, a_out*factor, b_out*factor], -1))
        fits = (candidate.min(-1) >= -1e-7) & (candidate.max(-1) <= 1+1e-7)
        lo, hi = np.where(fits, factor, lo), np.where(fits, hi, factor)
    result = from_lab(np.stack([light_out, a_out*lo, b_out*lo], -1))
    return np.clip(encode(result), 0, 1).astype(np.float32)


def grid(dimension=65):
    axis = np.linspace(0, 1, dimension, dtype=np.float32)
    b, g, r = np.meshgrid(axis, axis, axis, indexing="ij")
    return np.stack([r, g, b], -1).reshape(-1, 3)
