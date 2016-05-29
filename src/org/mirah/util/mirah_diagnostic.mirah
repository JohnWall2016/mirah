package org.mirah.util

import javax.tools.Diagnostic
import javax.tools.Diagnostic.Kind
import mirah.lang.ast.Position
import mirah.lang.ast.Node

class MirahDiagnostic implements Diagnostic
  def initialize(kind:Kind, position:Position, message:String, node:Node = nil)
    @kind = kind
    @position = position
    @message = message
    @node = node
  end
  
  def self.error(position:Position, message:String, node:Node = nil)
    MirahDiagnostic.new(Kind.ERROR, position, message, node)
  end
  
  def self.warning(position:Position, message:String, node:Node = nil)
    MirahDiagnostic.new(Kind.WARNING, position, message, node)
  end
  
  def self.note(position:Position, message:String, node:Node = nil)
    MirahDiagnostic.new(Kind.NOTE, position, message, node)
  end
  
  def getKind
    @kind
  end
  
  def getMessage(locale)
    @message
  end
  
  def getSource
    @position.source if @position
  end
  
  #TODO
  def getCode; nil; end
  
  def getColumnNumber:long
    if @position
      long(@position.startColumn)
    else
      Diagnostic.NOPOS
    end
  end
  
  def getEndPosition:long
    if @position
      long(@position.endChar)
    else
      Diagnostic.NOPOS
    end
  end
  
  def getLineNumber:long
    if @position
      long(@position.startLine)
    else
      Diagnostic.NOPOS
    end
  end
  
  def getPosition:long
    if @position
      long(@position.startChar)
    else
      Diagnostic.NOPOS
    end
  end
  
  def getStartPosition:long
    getPosition
  end

  def getNode:Node
    @node
  end
end
