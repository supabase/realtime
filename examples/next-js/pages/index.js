import React from 'react'
import axios from 'axios'
import { RealtimeClient } from '@supabase/realtime-js'

const REALTIME_URL = process.env.REALTIME_URL || 'ws://localhost:4000/socket'
import Link from 'next/link'

export default class Index extends React.Component {
  constructor() {
    super()
    this.state = {
      received: [],
      socketState: 'CONNECTING',
      users: [],
      todos: [],
    }
    this.messageReceived = this.messageReceived.bind(this)

    this.socket = new RealtimeClient(REALTIME_URL)
    this.channelList = []
  }
  componentDidMount() {
    this.socket.connect()
    this.addChannel('realtime:*')
    this.addChannel('realtime:public')
    this.addChannel('realtime:public:todos')
    this.addChannel('realtime:public:users')
    this.addChannel('realtime:public:users:id=eq.16')
    this.addChannel('realtime:public:users:id=eq.17')
    this.addChannel('realtime:public:users:id=eq.18')
    this.fetchData()
  }
  componentWillUnmount() {
    this.socket.disconnect()
  }
  addChannel(topic) {
    let channel = this.socket.channel(topic)
    channel.on('INSERT', msg => this.messageReceived(topic, msg))
    channel.on('*', msg => console.log('*', msg))
    channel.on('INSERT', msg => console.log('INSERT', msg))
    channel.on('UPDATE', msg => console.log('UPDATE', msg))
    channel.on('DELETE', msg => console.log('DELETE', msg))
    channel
      .subscribe()
      .receive('ok', () => console.log('Connecting'))
      .receive('error', () => console.log('Failed'))
      .receive('timeout', () => console.log('Waiting...'))
    this.channelList.push(channel)
  }
  messageReceived(channel, msg) {
    let received = [...this.state.received, { channel, msg }]
    this.setState({ received })
    if (channel === 'realtime:public:users') {
      this.setState({ users: [...this.state.users, msg.record] })
    }
    if (channel === 'realtime:public:todos') {
      this.setState({ todos: [...this.state.todos, msg.record] })
    }
  }
  async fetchData() {
    try {
      let { data: users } = await axios.get('/api/fetch/users')
      let { data: todos } = await axios.get('/api/fetch/todos')
      this.setState({ users, todos })
    } catch (error) {
      console.log('error', error)
    }
  }
  async insertUser() {
    let { data: user } = await axios.post('/api/new-user', {})
  }
  async insertTodo() {
    let { data: todo } = await axios.post('/api/new-todo', {})
  }
  render() {
    return (
      <div style={styles.main}>
        <a>index</a> | <Link href="/stress">stress chart</Link>
        <div style={styles.row}>
          <div style={styles.col}>
            <h3>Changes</h3>
            <p>Listening on {REALTIME_URL}</p>
            <p>Try opening two tabs and clicking the buttons!</p>
          </div>
          <div style={styles.col}>
            <h3>Users</h3>
            <button onClick={() => this.insertUser()}>Add random user</button>
          </div>
          <div style={styles.col}>
            <h3>Todos</h3>
            <button onClick={() => this.insertTodo()}>Add random todo</button>
          </div>
        </div>
        <div style={styles.row}>
          <div style={styles.col}>
            {this.state.received.map(x => (
              <div key={Math.random()}>
                <p>Received on {x.channel}</p>
                <pre style={styles.pre}>
                  <code style={styles.code}>{JSON.stringify(x.msg, null, 2)}</code>
                </pre>
              </div>
            ))}
          </div>
          <div style={styles.col}>
            {this.state.users.map(user => (
              <pre style={styles.pre} key={user.id}>
                <code style={styles.code}>{JSON.stringify(user, null, 2)}</code>
              </pre>
            ))}
          </div>
          <div style={styles.col}>
            {this.state.todos.map(todo => (
              <pre style={styles.pre} key={todo.id}>
                <code style={styles.code}>{JSON.stringify(todo, null, 2)}</code>
              </pre>
            ))}
          </div>
        </div>
      </div>
    )
  }
}

const styles = {
  main: { fontFamily: 'monospace', height: '100%', margin: 0, padding: 0 },
  pre: {
    whiteSpace: 'pre',
    overflow: 'auto',
    background: '#333',
    maxHeight: 200,
    borderRadius: 6,
    padding: 5,
  },
  code: { display: 'block', wordWrap: 'normal', color: '#fff' },
  row: { display: 'flex', flexDirection: 'row', height: '100%' },
  col: { width: '33%', maxWidth: '33%', padding: 10, height: '100%', overflow: 'auto' },
}
