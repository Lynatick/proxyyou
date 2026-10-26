package monitoring

func (q *testTaskQueue) drain() []*testTask {
	q.mu.Lock()
	defer q.mu.Unlock()
	pending := make([]*testTask, 0, q.priority.Len()+q.normal.Len())
	for element := q.priority.Front(); element != nil; element = element.Next() {
		task := element.Value.(*testTask)
		task.element = nil
		pending = append(pending, task)
	}
	for element := q.normal.Front(); element != nil; element = element.Next() {
		task := element.Value.(*testTask)
		task.element = nil
		pending = append(pending, task)
	}
	q.priority.Init()
	q.normal.Init()
	return pending
}
