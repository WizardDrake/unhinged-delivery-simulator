class_name BehaviorFlow
extends RefCounted

## Runs callables in order; the first step that returns true stops the chain.
var _steps: Array[Callable] = []


func add(step: Callable) -> BehaviorFlow:
	_steps.append(step)
	return self


func run(delta: float) -> void:
	for step in _steps:
		if step.call(delta):
			return
