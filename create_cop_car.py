import sys

tscn = """[gd_scene load_steps=5 format=3 uid="uid://c3q8f5g4h2j1"]

[ext_resource type="Texture2D" uid="uid://ddq5x3q2w1v0" path="res://assets/targeting_truck.png" id="1_tex"]
[ext_resource type="Script" path="res://cop_car.gd" id="2_script"]

[sub_resource type="RectangleShape2D" id="RectangleShape2D_car"]
size = Vector2(280, 140)

[sub_resource type="RectangleShape2D" id="RectangleShape2D_boot"]
size = Vector2(340, 200)

[node name="CopCar" type="CharacterBody2D" groups=["cop"]]
collision_layer = 1
collision_mask = 3
script = ExtResource("2_script")

[node name="Sprite2D" type="Sprite2D" parent="."]
texture = ExtResource("1_tex")

[node name="CollisionShape2D" type="CollisionShape2D" parent="."]
shape = SubResource("RectangleShape2D_car")

[node name="BootArea" type="Area2D" parent="."]
collision_layer = 0
collision_mask = 1

[node name="CollisionShape2D" type="CollisionShape2D" parent="BootArea"]
shape = SubResource("RectangleShape2D_boot")
"""

with open("cop_car.tscn", "w") as f:
    f.write(tscn)
