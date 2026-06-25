from PIL import Image
import math

size = 512
img = Image.new('RGBA', (size, size), (0, 0, 0, 0))

for x in range(size):
    for y in range(size):
        dx = x
        dy = y - size/2
        
        angle = math.atan2(dy, dx)
        cone_angle = math.radians(35) # 35 degree half-angle
        
        if abs(angle) <= cone_angle:
            dist = math.sqrt(dx*dx + dy*dy)
            dist_factor = max(0, 1.0 - (dist / size))
            angle_factor = max(0, 1.0 - (abs(angle) / cone_angle))
            
            intensity = dist_factor * angle_factor
            intensity = math.pow(intensity, 1.2) # less power = brighter overall
            
            val = int(intensity * 255)
            if val > 0:
                img.putpixel((x, y), (255, 255, 255, val))

img.save('assets/headlight.png')
