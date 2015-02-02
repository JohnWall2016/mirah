class ListExtensionsTest < Test::Unit::TestCase
  def test_empty_q
    cls, = compile(<<-EOF)
      x = []
      puts x.empty?
    EOF
    assert_output("true\n") do
      cls.main(nil)
    end
  end

  def test_bracket_getter
    cls, = compile(<<-EOF)
      x = [1,2]
      puts x[0]
    EOF
    assert_output("1\n") do
      cls.main(nil)
    end
  end

  def test_bracket_assignment
    cls, = compile(<<-EOF)
      import java.util.ArrayList
      x = ArrayList.new
      x[0]= "2"
      puts x
    EOF
    assert_output("[2]\n") do
      cls.main(nil)
    end
  end
end
