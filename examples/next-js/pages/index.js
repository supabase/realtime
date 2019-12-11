import { Socket } from 'phoenix-channels'

const SOCKET_URL = process.env.TEST_VAR || 'ws://localhost:4000/socket'

export default class Index extends React.Component {
  constructor() {
    super()
    this.state = {
      received: [],
      socketState: 'CONNECTING',
    }
    this.messageReceived = this.messageReceived.bind(this)

    this.socket = new Socket(SOCKET_URL)
    this.channelList = []
  }
  componentDidMount() {
    this.socket.connect()
    this.addChannel('realtime:*')
    this.addChannel('realtime:public:users')
  }
  addChannel(topic) {
    let channel = this.socket.channel(topic)
    channel.on('*', msg => this.messageReceived(topic, msg))
    channel
      .join()
      .receive('ok', () => console.log('Connecting'))
      .receive('error', () => console.log('Failed'))
      .receive('timeout', () => console.log('Waiting...'))
    this.channelList.push(channel)
  }
  messageReceived(channel, msg) {
    console.log('channel', channel)
    console.log('msg', msg)
    let received = [...this.state.received, { channel, msg }]
    this.setState({ received })
  }
  render() {
    return (
      <div style={styles.main}>
        <p>Listening on {SOCKET_URL}</p>
        {this.state.received.map(x => (
          <div key={Math.random()}>
            <p>Received on {x.channel}</p>
            <pre style={styles.pre}>
              <code style={styles.code}>{JSON.stringify(x.msg, null, 2)}</code>
            </pre>
          </div>
        ))}
      </div>
    )
  }
}

const styles = {
  main: { fontFamily: 'monospace', padding: 30 },
  pre: {
    whiteSpace: 'pre',
    overflow: 'auto',
    background: '#333',
    maxHeight: 200,
    borderRadius: 6,
    padding: 5,
  },
  code: { display: 'block', wordWrap: 'normal', color: '#fff' },
}
