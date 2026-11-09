import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
import './styles.css';

class ErrorBoundary extends React.Component {
  constructor(props){super(props);this.state={error:null};}
  static getDerivedStateFromError(error){return {error};}
  componentDidCatch(error){console.error('VALLEY render error:',error);}
  render(){
    if(this.state.error)return <main className="error-screen"><p className="eyebrow">VALLEY SYSTEM</p><h1>Something went wrong.</h1><p>Refresh the page. If this continues, send this error to the website developer.</p><pre>{String(this.state.error?.stack||this.state.error)}</pre><button onClick={()=>window.location.reload()}>Reload website</button></main>;
    return this.props.children;
  }
}
createRoot(document.getElementById('root')).render(<React.StrictMode><ErrorBoundary><App/></ErrorBoundary></React.StrictMode>);