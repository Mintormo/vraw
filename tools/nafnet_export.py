"""Экспорт NAFNet (megvii-research/NAFNet, MIT) в ONNX для AI-шумодава vraw.

Веса: NAFNet-SIDD-width32.pth (официальные, зеркало huggingface.co/mikestealth/nafnet-models).
Запуск (нужен PyTorch CPU): python nafnet_export.py NAFNet-SIDD-width32.pth 32 nafnet_sidd_w32.onnx
Результат положить в ~/.local/share/vraw/models/.
"""
import sys, torch, torch.nn as nn, torch.nn.functional as F

class LayerNorm2d(nn.Module):
    def __init__(self, c, eps=1e-6):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(c)); self.bias = nn.Parameter(torch.zeros(c)); self.eps = eps
    def forward(self, x):
        mu = x.mean(1, keepdim=True); var = (x - mu).pow(2).mean(1, keepdim=True)
        y = (x - mu) / (var + self.eps).sqrt()
        return self.weight.view(1, -1, 1, 1) * y + self.bias.view(1, -1, 1, 1)

class SimpleGate(nn.Module):
    def forward(self, x):
        a, b = x.chunk(2, dim=1); return a * b

class NAFBlock(nn.Module):
    def __init__(self, c):
        super().__init__()
        dw = c * 2
        self.conv1 = nn.Conv2d(c, dw, 1); self.conv2 = nn.Conv2d(dw, dw, 3, padding=1, groups=dw)
        self.conv3 = nn.Conv2d(dw // 2, c, 1)
        self.sca = nn.Sequential(nn.AdaptiveAvgPool2d(1), nn.Conv2d(dw // 2, dw // 2, 1))
        self.sg = SimpleGate()
        self.conv4 = nn.Conv2d(c, 2 * c, 1); self.conv5 = nn.Conv2d(c, c, 1)
        self.norm1 = LayerNorm2d(c); self.norm2 = LayerNorm2d(c)
        self.beta = nn.Parameter(torch.zeros(1, c, 1, 1)); self.gamma = nn.Parameter(torch.zeros(1, c, 1, 1))
    def forward(self, inp):
        x = self.sg(self.conv2(self.conv1(self.norm1(inp))))
        x = self.conv3(x * self.sca(x))
        y = inp + x * self.beta
        x = self.conv5(self.sg(self.conv4(self.norm2(y))))
        return y + x * self.gamma

class NAFNet(nn.Module):
    def __init__(self, width, middle=12, enc=(2, 2, 4, 8), dec=(2, 2, 2, 2)):
        super().__init__()
        self.intro = nn.Conv2d(3, width, 3, padding=1); self.ending = nn.Conv2d(width, 3, 3, padding=1)
        self.encoders = nn.ModuleList(); self.decoders = nn.ModuleList()
        self.ups = nn.ModuleList(); self.downs = nn.ModuleList()
        ch = width
        for n in enc:
            self.encoders.append(nn.Sequential(*[NAFBlock(ch) for _ in range(n)]))
            self.downs.append(nn.Conv2d(ch, 2 * ch, 2, 2)); ch *= 2
        self.middle_blks = nn.Sequential(*[NAFBlock(ch) for _ in range(middle)])
        for n in dec:
            self.ups.append(nn.Sequential(nn.Conv2d(ch, ch * 2, 1, bias=False), nn.PixelShuffle(2))); ch //= 2
            self.decoders.append(nn.Sequential(*[NAFBlock(ch) for _ in range(n)]))
    def forward(self, inp):  # H, W кратны 16 - обеспечивает вызывающий
        x = self.intro(inp); skips = []
        for e, d in zip(self.encoders, self.downs):
            x = e(x); skips.append(x); x = d(x)
        x = self.middle_blks(x)
        for dcd, up, s in zip(self.decoders, self.ups, skips[::-1]):
            x = dcd(up(x) + s)
        return self.ending(x) + inp

pth, width, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
m = NAFNet(width).eval()
sd = torch.load(pth, map_location="cpu", weights_only=False)
sd = sd.get("params", sd)
print(m.load_state_dict(sd, strict=True))
x = torch.rand(1, 3, 256, 256)
torch.onnx.export(m, x, out, input_names=["image"], output_names=["denoised"], opset_version=17,
                  dynamic_axes={"image": {2: "h", 3: "w"}, "denoised": {2: "h", 3: "w"}}, dynamo=False)
print("ok", out)
