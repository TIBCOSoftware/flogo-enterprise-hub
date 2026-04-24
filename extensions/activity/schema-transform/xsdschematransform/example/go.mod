module example

go 1.21

replace github.com/project-flogo/custom-extensions/activity/xsdschematransform => ../

require (
	github.com/project-flogo/core v1.6.0
	github.com/project-flogo/custom-extensions/activity/xsdschematransform v0.0.0-00010101000000-000000000000
)

require (
	github.com/araddon/dateparse v0.0.0-20200409225146-d820a6159ab1 // indirect
	go.uber.org/atomic v1.6.0 // indirect
	go.uber.org/multierr v1.5.0 // indirect
	go.uber.org/zap v1.16.0 // indirect
)
